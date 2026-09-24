# Self-reported document rewards

`GET /api/quests/documents` returns the authenticated owner's dogs, preserved
submission versions and per-dog eligibility. `POST` accepts a UUID `request_id`,
`dog_id`, and `kind`, with the corresponding fields below. It immediately records
`SELF_REPORTED` evidence and awards an eligible canonical `PointEntry`. This does
not verify a certificate or imply that an audit occurred.

- `COUNCIL_REGISTRATION`: 300 points once per dog. A bounded registration number,
  a PDF, or both. No inferred document date.
- `MICROCHIP_REGISTRATION`: 300 points per annual registration period. Number or
  PDF, plus `valid_from` and `valid_to`. The end must be the first anniversary or
  its preceding day; a new reward's period must cover today. Overlapping annual
  periods use the existing entitlement and award zero. Adjacent anniversary
  periods are distinct. The February 29 anniversary clamps to February 28.
- `VET_CHECKUP`: 200 points per actual `event_date`, maximum twice in its calendar
  year, with at least 60 days between rewarded event dates across year boundaries.
  A JPEG/PNG photo is required. Future visit dates are rejected. No unconfirmed
  historical look-back limit is imposed.

Re-uploading for an existing entitlement preserves another submission and adds
zero points. Retries with the same request ID replay the original JSON receipt
(including its original balance); conflicting reuse returns 409. Owner and dog
locks serialize claims. Entitlements remain attached to dog identity even if an
admin transfers the profile. Identical file fingerprints cannot support a new
entitlement; the same registration number may be renewed in a later annual
period. Fingerprints are scoped per dog: a family certificate or photo can cover several
dogs, while a single dog cannot reuse its file to earn another entitlement.
Disabling the Documents catalog entry blocks new submissions with 409 before
any evidence or points are saved; successful request retries, submission history
and authenticated downloads remain available.

JSON uploads are bounded at 4 MiB decoded and the request parser at 6 MiB. PDFs
must parse, have 1–20 pages and be unencrypted. Vet photos must decode as JPEG or
PNG and be at most 16 megapixels. Files are not OCR-checked. Submitted bytes are
retained unchanged under generated names in `PRIVATE_MEDIA_ROOT`, never public
`MEDIA_ROOT`; the database and private files must be backed up together.

`GET /api/quests/documents/{id}/file` permits only the submitting owner or an
admin (JWT, or an authenticated Django admin session). It returns an attachment
with private/no-store, nosniff and sandbox headers. The admin page is read-only;
original submissions cannot be overwritten or removed there. Deleting a dog
retains its name/ID snapshots, reward entitlement, ledger entry and evidence.
