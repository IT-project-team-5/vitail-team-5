from django.contrib.auth import get_user_model
from rest_framework import status
from rest_framework.test import APITestCase

from dogs.models import Breed, Dog


User = get_user_model()


class DogApiTests(APITestCase):
    list_url = "/api/dogs"
    breed_url = "/api/dogs/breeds"

    @classmethod
    def setUpTestData(cls):
        cls.breed = Breed.objects.create(
            name="Test Terrier",
            energy_level=Breed.EnergyLevel.MODERATE,
            default_size=Breed.Size.SMALL,
            is_brachycephalic=False,
        )
        cls.flat_faced_breed = Breed.objects.create(
            name="Test Flat Face",
            energy_level=Breed.EnergyLevel.LOW,
            default_size=Breed.Size.SMALL,
            is_brachycephalic=True,
        )

    def setUp(self):
        self.owner = User.objects.create_user(
            email="owner@example.com",
            password="StrongPass123!",
            display_name="Owner",
            role=User.Role.OWNER,
        )
        self.other_owner = User.objects.create_user(
            email="other@example.com",
            password="StrongPass123!",
            display_name="Other",
            role=User.Role.OWNER,
        )
        self.client.force_authenticate(self.owner)

    def dog_payload(self, **overrides):
        payload = {
            "name": "Milo",
            "breed_id": self.breed.id,
            "age_months": 36,
            "size": Dog.Size.SMALL,
            "is_brachycephalic": False,
        }
        payload.update(overrides)
        return payload

    def create_dog(self, owner=None, **overrides):
        values = {
            "owner": owner or self.owner,
            "name": "Milo",
            "breed": self.breed,
            "age_months": 36,
            "size": Dog.Size.SMALL,
            "is_brachycephalic": False,
        }
        values.update(overrides)
        return Dog.objects.create(**values)

    def test_owner_can_create_dog_and_server_assigns_owner(self):
        response = self.client.post(self.list_url, self.dog_payload(), format="json")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        dog = Dog.objects.get(pk=response.data["id"])
        self.assertEqual(dog.owner, self.owner)
        self.assertEqual(response.data["breed"]["name"], self.breed.name)

    def test_client_cannot_assign_dog_to_another_owner(self):
        response = self.client.post(
            self.list_url,
            self.dog_payload(owner=self.other_owner.id, owner_id=self.other_owner.id),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(Dog.objects.get(pk=response.data["id"]).owner, self.owner)

    def test_owner_lists_only_own_dogs(self):
        mine = self.create_dog(name="Mine")
        self.create_dog(owner=self.other_owner, name="Not Mine")

        response = self.client.get(self.list_url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual([item["id"] for item in response.data], [mine.id])

    def test_owner_can_patch_own_dog_without_reassigning_owner(self):
        dog = self.create_dog()

        response = self.client.patch(
            f"{self.list_url}/{dog.id}",
            {"name": "Updated", "owner_id": self.other_owner.id},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        dog.refresh_from_db()
        self.assertEqual(dog.name, "Updated")
        self.assertEqual(dog.owner, self.owner)

    def test_owner_cannot_patch_another_owners_dog(self):
        dog = self.create_dog(owner=self.other_owner)

        response = self.client.patch(
            f"{self.list_url}/{dog.id}",
            {"name": "Stolen"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)
        dog.refresh_from_db()
        self.assertEqual(dog.name, "Milo")

    def test_ten_dogs_allowed_and_eleventh_rejected(self):
        for index in range(10):
            response = self.client.post(
                self.list_url,
                self.dog_payload(name=f"Dog {index + 1}"),
                format="json",
            )
            self.assertEqual(response.status_code, status.HTTP_201_CREATED)

        response = self.client.post(
            self.list_url,
            self.dog_payload(name="Dog 11"),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("at most 10 dogs", str(response.data))
        self.assertEqual(Dog.objects.filter(owner=self.owner).count(), 10)

    def test_invalid_breed_is_rejected(self):
        response = self.client.post(
            self.list_url,
            self.dog_payload(breed_id=999999),
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("breed_id", response.data)

    def test_invalid_size_is_rejected(self):
        response = self.client.post(
            self.list_url,
            self.dog_payload(size="GIANT"),
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("size", response.data)

    def test_negative_age_is_rejected(self):
        response = self.client.post(
            self.list_url,
            self.dog_payload(age_months=-1),
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("age_months", response.data)

    def test_omitted_brachycephalic_defaults_from_breed(self):
        payload = self.dog_payload(breed_id=self.flat_faced_breed.id)
        del payload["is_brachycephalic"]

        response = self.client.post(self.list_url, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertTrue(response.data["is_brachycephalic"])

    def test_explicit_brachycephalic_can_override_breed(self):
        response = self.client.post(
            self.list_url,
            self.dog_payload(
                breed_id=self.flat_faced_breed.id,
                is_brachycephalic=False,
            ),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertFalse(response.data["is_brachycephalic"])

    def test_breed_endpoint_is_read_only_reference_data(self):
        response = self.client.get(self.breed_url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        item = next(item for item in response.data if item["id"] == self.breed.id)
        self.assertEqual(
            set(item),
            {"id", "name", "energy_level", "default_size", "is_brachycephalic"},
        )
        self.assertEqual(
            self.client.post(self.breed_url, {}, format="json").status_code,
            status.HTTP_405_METHOD_NOT_ALLOWED,
        )

    def test_goal_endpoint_returns_inputs_without_invented_duration(self):
        dog = self.create_dog()

        response = self.client.get(f"{self.list_url}/{dog.id}/goal")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], "RULES_PENDING")
        self.assertIsNone(response.data["recommended_duration_minutes"])
        self.assertEqual(response.data["factors"]["age_months"], dog.age_months)

    def test_goal_endpoint_does_not_expose_another_owners_dog(self):
        dog = self.create_dog(owner=self.other_owner)
        response = self.client.get(f"{self.list_url}/{dog.id}/goal")
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_dog_endpoints_require_authenticated_owner(self):
        self.client.force_authenticate(user=None)
        self.assertEqual(
            self.client.get(self.list_url).status_code,
            status.HTTP_401_UNAUTHORIZED,
        )

        cafe = User.objects.create_user(
            email="cafe@example.com",
            password="StrongPass123!",
            display_name="Cafe",
            role=User.Role.CAFE,
        )
        self.client.force_authenticate(cafe)
        self.assertEqual(
            self.client.get(self.list_url).status_code,
            status.HTTP_403_FORBIDDEN,
        )
