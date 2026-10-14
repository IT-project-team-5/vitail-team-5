# Melbourne venue snapshot

The explicit import supplies three veterinary clinics and three public parks.
It does not run during startup/migration, create café accounts, or claim that
the clinics are Vitail partners. Onboard partner cafés/restaurants in Admin
using their confirmed location and partnership settings.

From `backend`, after applying migrations:

```bash
python manage.py import_melbourne_venues --dry-run
python manage.py import_melbourne_venues
```

The command validates the whole file before writing, inserts atomically, and
preserves existing places on repeated runs. Stable source identities and a
same-category/name check within 50 metres prevent duplicate imports. Existing
manual/managed records retain their coordinates, address, account and enabled
flags. A custom `--file path.csv` must follow the bundled CSV schema and contain
Greater Melbourne park/vet records with supported source identities.

## Source and coordinate choices

The [snapshot](../backend/venues/data/melbourne_venues.csv) was checked on
9 October 2026. Each row records its source and a verification URL.

Veterinary coordinates come from **nodes**, not bounding-box centres, in an
OpenStreetMap Overpass extract. Clinic-owned contact pages independently
confirm the name/address. These records are derived from
[OpenStreetMap contributors](https://www.openstreetmap.org/copyright), licensed
under ODbL; preserve their attribution and source references when redistributing
the snapshot. No real-time OSM dependency is added to the app.

Park points use each Yarra City Council page's **Get directions** destination.
They represent a specific navigation/check-in point rather than an entire park
boundary. A 20-metre check-in circle is drawn around that point. Browns Reserve's
OSM centre is about 48 metres from the council point; Gahan Reserve's OSM
address differs from the council listing. The snapshot deliberately uses the
council's factual address/navigation point for these parks. Only these facts
are included; no council descriptions or images are reproduced and no open
licence for council website content is claimed. See the
[council terms](https://www.yarracity.vic.gov.au/about-us/about-yarra/disclaimer).

Dataset provenance is stored separately from café management. Site conditions
and GPS reception must be checked during the physical-phone acceptance run;
the imported coordinates alone do not certify a usable 20-metre arrival point.
The supplied parks include leash rules/zones: consult the linked park pages
before planning the test route. Adjust a confirmed point in Admin if necessary;
rerunning the import preserves that correction.
