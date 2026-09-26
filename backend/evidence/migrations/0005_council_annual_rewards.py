from zoneinfo import ZoneInfo

from django.db import migrations, models


def council_years(apps, alias):
    Entitlement = apps.get_model("evidence", "DocumentEntitlement")
    Submission = apps.get_model("evidence", "DocumentSubmission")
    melbourne = ZoneInfo("Australia/Melbourne")
    mapped, seen = [], {}
    for entitlement in Entitlement.objects.using(alias).filter(kind="COUNCIL_REGISTRATION").order_by("pk").iterator():
        first = Submission.objects.using(alias).filter(entitlement_id=entitlement.pk).order_by("submitted_at", "pk").first()
        if first and first.registration_year is not None:
            year = first.registration_year
        else:
            # Never infer from a later re-upload or migration execution date.
            day = (first.submitted_at if first else entitlement.created_at).astimezone(melbourne).date()
            year = day.year + ((day.month, day.day) >= (4, 10))
        key = (entitlement.dog_id_snapshot, year)
        if key in seen or year < 1:
            raise RuntimeError(f"Cannot map Council entitlement {entitlement.pk}: conflicting or invalid original registration year. Review historical records before retrying this migration.")
        seen[key] = entitlement.pk
        mapped.append((entitlement.pk, year))
    return mapped


def preflight_council_years(apps, schema_editor):
    # Fail before DDL on MySQL if unexpected legacy duplicates need review.
    council_years(apps, schema_editor.connection.alias)


def backfill_council_year(apps, schema_editor):
    Entitlement = apps.get_model("evidence", "DocumentEntitlement")
    alias = schema_editor.connection.alias
    mapped = council_years(apps, alias)
    # Validate every mapping first; never merge, discard or award historical rows.
    for pk, year in mapped:
        Entitlement.objects.using(alias).filter(pk=pk).update(registration_year=year)


class Migration(migrations.Migration):
    dependencies = [("evidence", "0004_registration_details")]

    operations = [
        migrations.RunPython(preflight_council_years, migrations.RunPython.noop),
        migrations.AddField(
            model_name="documententitlement", name="registration_year",
            field=models.PositiveSmallIntegerField(blank=True, null=True),
        ),
        migrations.RunPython(backfill_council_year, migrations.RunPython.noop),
        migrations.AddConstraint(
            model_name="documententitlement",
            constraint=models.UniqueConstraint(fields=("dog_id_snapshot", "kind", "registration_year"), name="council_dog_year_unique"),
        ),
        migrations.AddConstraint(
            model_name="documententitlement",
            constraint=models.CheckConstraint(condition=(
                models.Q(kind="COUNCIL_REGISTRATION", registration_year__isnull=False, registration_year__gte=1)
                | (~models.Q(kind="COUNCIL_REGISTRATION") & models.Q(registration_year__isnull=True))
            ), name="council_reward_year_shape"),
        ),
    ]
