from django.db import migrations, models


def backfill_collected_at(apps, schema_editor):
    entitlement = apps.get_model("evidence", "DocumentEntitlement")
    alias = schema_editor.connection.alias
    for row in entitlement.objects.using(alias).filter(point_entry__isnull=False).select_related("point_entry").iterator():
        entitlement.objects.using(alias).filter(pk=row.pk, collected_at__isnull=True).update(collected_at=row.point_entry.created_at)


class Migration(migrations.Migration):
    dependencies = [("evidence", "0001_initial")]
    operations = [
        migrations.AddField(model_name="documententitlement", name="collected_at", field=models.DateTimeField(blank=True, null=True)),
        migrations.RunPython(backfill_collected_at, migrations.RunPython.noop),
    ]
