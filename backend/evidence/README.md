# Self-reported document rewards

`GET /api/quests/documents` returns the authenticated owner's dogs, preserved
submission versions, per-dog eligibility and reward entitlements. `POST` accepts
a UUID `request_id`, `dog_id`, and `kind`, with the fields below. Submission
records `SELF_REPORTED` evidence and reserves a `READY` entitlement. It awards
zero points. This does not verify a certificate or imply that an audit occurred.

- `COUNCIL_REGISTRATION`: 300 points once per dog. A bounded registration number,
  a PDF, or both. No inferred document date.
- `MICROCHIP_REGISTRATION`: 300 points per annual registration period. Number or
  PDF, plus `valid_from` and `valid_to`. The end must be the first anniversary or
  its preceding day; a new reservation's period must cover today. Overlapping
  annual periods use the existing entitlement. Adjacent anniversary periods are
  distinct. The February 29 anniversary clamps to February 28.
- `VET_CHECKUP`: 200 points per actual `event_date`, maximum twice in its calendar
  year, with at least 60 days between reserved event dates across year boundaries.
  A JPEG/PNG photo is required. Future dates and visits before a known birthday
  are rejected. No unconfirmed historical look-back limit is imposed.

`POST /api/quests/documents/entitlements/{id}/collect` with `{}` explicitly credits
the canonical point ledger and returns
`{entitlement_id,kind,dog_id,points,balance,collected_at,created}`. Collection locks
the owner, dog and entitlement; retries return `created:false` without another
credit. An uncollected entitlement requires the current dog's owner to have
submitted evidence. A credited entitlement can only be replayed by its historical
point recipient, even after transfer/deletion. Dog transfers never reset quota.

The submit receipt adds `entitlement_id`, `reward_status`, `reward_points` and
`collected_at`, also present on the submission object. New submit receipts always
have `awarded_points:0`. Original submit receipts remain immutable: retries replay
their original status and balance even after collection. The dashboard gives the
current state; `awards_count` counts credited entitlements, `pending_count` counts
reserved ones, and vet remaining slots include reservations. Legacy receipts,
point entries, files and submission-level awarded amounts remain unchanged. The
additive migration backfills legacy collection times from linked ledger entries.

Re-uploading preserves another version of the original entitlement and never
creates a second reward. Conflicting request-ID reuse returns 409. Per-dog file
fingerprints cannot support a different entitlement; the same registration number
may be renewed in a later annual period. A family certificate/photo can support
several dogs. Disabling Documents blocks new submissions and uncollected rewards
with 409; successful request/collection retries, history and downloads remain.

`evidence.services.quest_tasks(owner=...,dogs=...,request=...,now=...)` returns
compact IN_PROGRESS, READY and COLLECTED task rows. Pending rewards suppress
additional tasks of that dog/type. COLLECTED tasks are shown only on their
collection's Melbourne date, while document history remains available. Former
owners see their evidence's dog-name snapshot, not the transferred dog's profile.

JSON uploads are bounded at 4 MiB decoded and the request parser at 6 MiB. PDFs
must parse, have 1–20 pages and be unencrypted. Vet photos must decode as JPEG or
PNG and be at most 16 megapixels. Files are not OCR-checked. Submitted bytes remain
unchanged under generated names in `PRIVATE_MEDIA_ROOT`, never public
`MEDIA_ROOT`; the database and private files must be backed up together. Partial
write failures remove only the newly created file and database work rolls back.

`GET /api/quests/documents/{id}/file` permits only the submitting owner or an
admin (JWT, or an authenticated Django admin session). It returns an attachment
with private/no-store, nosniff and sandbox headers. The admin page is read-only;
original submissions cannot be overwritten or removed there. Deleting a dog
retains its name/ID snapshots, reward entitlement, ledger entry and evidence.
