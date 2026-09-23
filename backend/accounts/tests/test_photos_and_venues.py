import base64
import io
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

from django.core.files.storage import default_storage
from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.test import TransactionTestCase, override_settings
from PIL import Image
from rest_framework.test import APITestCase

from accounts.models import CafeProfile, User
from accounts.photos import MAX_IMAGE_BYTES
from dogs.models import Breed, Dog
from rewards.models import Reward
from rewards.services import create_redemption, credit_points


def encoded_image(size=(48, 36), format="PNG", metadata=False):
    output = io.BytesIO()
    image = Image.new("RGB", size, "gold")
    kwargs = {}
    if metadata:
        exif = Image.Exif()
        exif[0x010E] = "Private camera location metadata"
        exif[0x0112] = 6
        kwargs["exif"] = exif
    image.save(output, format=format, **kwargs)
    return base64.b64encode(output.getvalue()).decode()


class PhotoAndVenueApiTests(APITestCase):
    @classmethod
    def setUpTestData(cls):
        cls.owner = User.objects.create_user(email="avatar-owner@example.com", display_name="Owner", password="PrivatePass123!")
        cls.other = User.objects.create_user(email="avatar-other@example.com", display_name="Other Owner")
        cls.cafe = User.objects.create_user(email="avatar-cafe@example.com", display_name="Dog & Coffee", role="CAFE")
        cls.other_cafe = User.objects.create_user(email="avatar-other-cafe@example.com", display_name="Other Café", role="CAFE")
        cls.breed, _ = Breed.objects.get_or_create(name="Avatar Test Breed", defaults={"energy_level": "MODERATE", "default_size": "MEDIUM"})
        cls.dog = Dog.objects.create(owner=cls.owner, name="Coco", breed=cls.breed, age_months=12, size="MEDIUM", is_brachycephalic=False, photo="https://example.com/legacy.jpg")
        cls.profile = CafeProfile.objects.create(user=cls.cafe, address="15 Garden St, Melbourne", description="A dog-friendly garden.", opening_hours="Daily 8–4")
        cls.reward = Reward.objects.create(cafe_user=cls.cafe, name="Coffee", point_cost=60)

    def setUp(self):
        self.media = tempfile.TemporaryDirectory()
        self.addCleanup(self.media.cleanup)
        self.settings_override = override_settings(MEDIA_ROOT=self.media.name)
        self.settings_override.enable()
        self.addCleanup(self.settings_override.disable)
        self.client.force_authenticate(self.owner)

    def upload(self, path="/api/auth/me/photo", **kwargs):
        return self.client.post(path, {"image_base64": encoded_image(**kwargs)}, format="json")

    def test_photo_is_persisted_and_returned_as_absolute_url_on_all_auth_responses(self):
        response = self.upload(metadata=True, format="JPEG")
        self.assertEqual(response.status_code, 200)
        url = response.data["user"]["photo"]
        self.assertTrue(url.startswith("http://testserver/media/avatars/people/"))
        self.owner.refresh_from_db()
        self.assertTrue(default_storage.exists(self.owner.photo.name))
        with default_storage.open(self.owner.photo.name, "rb") as file:
            image = Image.open(file)
            self.assertEqual(image.format, "JPEG")
            self.assertFalse(image.getexif())
            self.assertEqual(image.size, (36, 48))  # EXIF orientation was applied.
        self.assertEqual(self.client.get("/api/auth/me").data["photo"], url)
        self.assertEqual(self.client.patch("/api/auth/me", {"display_name": "Updated"}, format="json").data["photo"], url)
        self.client.force_authenticate(None)
        login = self.client.post("/api/auth/login", {"email": self.owner.email, "password": "PrivatePass123!"}, format="json")
        self.assertEqual(login.data["user"]["photo"], url)

    def test_avatar_replacement_uses_unique_name_and_deletes_old_file_after_commit(self):
        first = self.upload().data["user"]["photo"]
        old_name = User.objects.get(pk=self.owner.pk).photo.name
        with self.captureOnCommitCallbacks(execute=True):
            second = self.upload().data["user"]["photo"]
        self.assertNotEqual(first, second)
        self.assertFalse(default_storage.exists(old_name))
        self.assertTrue(default_storage.exists(User.objects.get(pk=self.owner.pk).photo.name))

    def test_invalid_unsupported_and_oversized_images_do_not_change_previous_photo(self):
        self.upload()
        original = User.objects.get(pk=self.owner.pk).photo.name
        invalid = ["bad!!!", base64.b64encode(b"not an image").decode(), encoded_image(format="GIF"), encoded_image(size=(4100, 4100)), base64.b64encode(b"x" * (MAX_IMAGE_BYTES + 1)).decode()]
        for value in invalid:
            with self.subTest(prefix=value[:20]):
                response = self.client.post("/api/auth/me/photo", {"image_base64": value}, format="json")
                self.assertEqual(response.status_code, 400)
                self.assertIn("image_base64", response.data)
        self.assertEqual(User.objects.get(pk=self.owner.pk).photo.name, original)
        self.assertEqual(len(list(Path(self.media.name).rglob("*.jpg"))), 1)

    def test_oversized_json_body_is_rejected_before_image_processing(self):
        response = self.client.post("/api/auth/me/photo", b'{"image_base64":"' + b"x" * (6 * 1024 * 1024) + b'"}', content_type="application/json")
        self.assertEqual(response.status_code, 400)
        self.assertFalse(User.objects.get(pk=self.owner.pk).photo)

    def test_large_valid_photo_is_resized_and_file_can_be_served_by_local_media_route(self):
        response = self.upload(size=(2200, 1600))
        self.assertEqual(response.status_code, 200)
        self.owner.refresh_from_db()
        with self.owner.photo.open("rb") as photo:
            self.assertEqual(Image.open(photo).size, (1024, 745))
        # Django excludes development media routing when DEBUG=False (test default).
        # Exercise the same static view mounted by config.urls during local development.
        from django.views.static import serve
        from django.test import RequestFactory
        path = urlsplit(response.data["user"]["photo"]).path.removeprefix("/media/")
        served = serve(RequestFactory().get("/media/" + path), path, document_root=self.media.name)
        self.assertEqual(served.status_code, 200)
        self.assertEqual(served["Content-Type"], "image/jpeg")
        self.assertTrue(b"".join(served.streaming_content))
        # This view was called directly, outside Django's test client.
        # FileResponse.close() emits request_finished and would close the active
        # MySQL test transaction; only release the file opened by this view.
        served.file_to_stream.close()

    def test_existing_external_dog_photo_is_preserved_until_upload_and_other_owner_is_denied(self):
        self.assertEqual(self.client.get("/api/dogs").data[0]["photo"], "https://example.com/legacy.jpg")
        response = self.upload(f"/api/dogs/{self.dog.pk}/photo")
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data["photo"].startswith("http://testserver/media/avatars/dogs/"))
        self.assertEqual(self.client.get("/api/dogs").data[0]["photo"], response.data["photo"])
        self.dog.refresh_from_db()
        self.assertEqual(self.dog.photo, "https://example.com/legacy.jpg")
        name = self.dog.uploaded_photo.name
        self.client.force_authenticate(self.other)
        self.assertEqual(self.upload(f"/api/dogs/{self.dog.pk}/photo").status_code, 404)
        self.dog.refresh_from_db()
        self.assertEqual(self.dog.uploaded_photo.name, name)
        self.assertEqual(self.upload(f"/api/dogs/{self.dog.pk + 999}/photo").status_code, 404)

    def test_photo_endpoints_require_authentication_and_correct_role(self):
        self.assertEqual(self.upload("/api/cafe/profile/photo").status_code, 403)
        self.client.force_authenticate(self.cafe)
        self.assertEqual(self.upload(f"/api/dogs/{self.dog.pk}/photo").status_code, 403)
        self.client.force_authenticate(None)
        for path in ("/api/auth/me/photo", "/api/cafe/profile/photo", f"/api/dogs/{self.dog.pk}/photo"):
            self.assertEqual(self.upload(path).status_code, 401)
        self.assertFalse(list(Path(self.media.name).rglob("*.jpg")))

    def test_cafe_photo_is_shared_with_account_catalogue_and_order_without_mutating_snapshots(self):
        credit_points(user=self.owner, amount=100)
        order = create_redemption(owner=self.owner, reward_id=self.reward.pk)
        self.client.force_authenticate(self.cafe)
        photo = self.upload("/api/cafe/profile/photo").data["photo"]
        self.cafe.refresh_from_db()  # force_authenticate reuses this instance across requests.
        self.assertEqual(self.client.get("/api/auth/me").data["photo"], photo)
        self.assertEqual(self.client.get("/api/cafe/profile").data["photo"], photo)
        self.client.patch("/api/cafe/profile", {"name": "New Name"}, format="json")
        self.client.force_authenticate(self.other_cafe)
        self.assertIsNone(self.client.get("/api/cafe/profile").data["photo"])
        self.client.force_authenticate(self.owner)
        reward = self.client.get("/api/redemptions/rewards").data[0]
        redemption = self.client.get("/api/redemptions").data[0]
        for data in (reward, redemption):
            self.assertEqual(data["cafe_id"], self.cafe.pk)
            self.assertEqual(data["cafe_photo"], photo)
            self.assertEqual(data["cafe_address"], "15 Garden St, Melbourne")
            self.assertEqual(data["cafe_description"], "A dog-friendly garden.")
            self.assertEqual(data["cafe_opening_hours"], "Daily 8–4")
            self.assertIn("api=1&query=New+Name", data["cafe_google_maps_url"])
        self.assertEqual(redemption["cafe_name_snapshot"], "Dog & Coffee")
        self.assertEqual(redemption["point_cost_snapshot"], 60)
        collected = self.client.post(f"/api/redemptions/{order.pk}/collect", {}, format="json")
        self.assertEqual(collected.data["cafe_photo"], photo)

    def test_maps_links_can_be_saved_or_cleared_and_untrusted_hosts_are_rejected(self):
        self.client.force_authenticate(self.cafe)
        accepted = ["https://maps.app.goo.gl/Example", "https://goo.gl/maps/Example", "https://www.google.com/maps/place/Coffee", "https://maps.google.com/?q=Coffee", "https://www.google.com.au/maps/search/Coffee"]
        for value in accepted:
            response = self.client.patch("/api/cafe/profile", {"google_maps_url": value}, format="json")
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.data["google_maps_url"], value)
        for value in ("javascript:alert(1)", "https://evil.example/maps", "https://www.google.com.evil.example/maps", "https://google.com/search", "https://user:password@google.com/maps"):
            response = self.client.patch("/api/cafe/profile", {"google_maps_url": value}, format="json")
            self.assertEqual(response.status_code, 400)
        response = self.client.patch("/api/cafe/profile", {"google_maps_url": ""}, format="json")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["google_maps_url"], "")
        self.assertIn("query=Dog+%26+Coffee%2C+15+Garden+St%2C+Melbourne", response.data["maps_link"])
        changed = self.client.patch("/api/cafe/profile", {"address": "2 New Street", "google_maps_url": response.data["google_maps_url"]}, format="json")
        self.assertIn("2+New+Street", changed.data["maps_link"])

    def test_catalogue_handles_legacy_cafe_without_profile(self):
        Reward.objects.create(cafe_user=self.other_cafe, name="Tea", point_cost=40)
        reward = next(row for row in self.client.get("/api/redemptions/rewards").data if row["cafe_id"] == self.other_cafe.pk)
        self.assertEqual(reward["cafe_address"], "")
        self.assertIsNone(reward["cafe_photo"])
        self.assertTrue(reward["cafe_google_maps_url"].startswith("https://www.google.com/maps/search/"))
        self.assertFalse(CafeProfile.objects.filter(user=self.other_cafe).exists())


class AvatarMigrationTests(TransactionTestCase):
    def test_additive_migrations_preserve_existing_profiles_and_dog_urls(self):
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        old = [("accounts", "0002_cafeprofile"), ("dogs", "0001_initial")]
        try:
            executor.migrate(old)
            apps = executor.loader.project_state(old).apps
            old_user = apps.get_model("accounts", "User").objects.create(email="legacy-photo@example.com", display_name="Legacy", role="CAFE", password="unchanged-password-hash")
            apps.get_model("accounts", "CafeProfile").objects.create(user=old_user, address="Original address", description="Original description", opening_hours="9–5")
            breed = apps.get_model("dogs", "Breed").objects.create(name="Migration photo breed", energy_level="LOW", default_size="SMALL")
            old_dog = apps.get_model("dogs", "Dog").objects.create(owner=old_user, breed=breed, name="Legacy Dog", photo="https://example.com/dog.jpg", age_months=24, size="SMALL", is_brachycephalic=False)
            MigrationExecutor(connection).migrate(latest)
            user = User.objects.get(pk=old_user.pk)
            dog = Dog.objects.get(pk=old_dog.pk)
            self.assertEqual(user.password, "unchanged-password-hash")
            self.assertFalse(user.photo)
            self.assertEqual(user.cafe_profile.address, "Original address")
            self.assertEqual(user.cafe_profile.description, "Original description")
            self.assertEqual(user.cafe_profile.opening_hours, "9–5")
            self.assertEqual(user.cafe_profile.google_maps_url, "")
            self.assertEqual(dog.photo, "https://example.com/dog.jpg")
            self.assertFalse(dog.uploaded_photo)
        finally:
            MigrationExecutor(connection).migrate(latest)
