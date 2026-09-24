from django.db import migrations


class Migration(migrations.Migration):
    dependencies = [("accounts", "0003_cafeprofile_google_maps_url_user_photo"), ("rewards", "0003_venue_catalogue")]
    operations = [migrations.DeleteModel(name="CafeProfile")]
