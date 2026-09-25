# Self-reported document rewards

`GET /api/quests/documents` returns the authenticated owner's dogs, preserved
submission versions, per-dog eligibility and reward entitlements. `POST` accepts
a UUID `request_id`, `dog_id`, and `kind`, with the fields below. Submission
records `SELF_REPORTED` evidence and reserves a `READY` entitlement. It awards
zero points. This does not verify a certificate or imply that an audit occurred.

- `COUNCIL_REGISTRATION`: 300 points once per dog. Enter `registration_number`,
  `council_name` and `registration_year`, or upload proof. Manual numbers allow
  ASCII letters/digits, spaces and hyphens (1–100 characters, including at least
  one letter/digit). Leading zeroes are preserved. Council names allow up to 100
  printable characters. The year is the ending year of the current Victorian
  registration period (10 April–9 April), evaluated in Melbourne time: e.g.
  `2027` represents 10 April 2026–9 April 2027. This describes the evidence's
  validity, not an annual Vitail reward.
- `MICROCHIP_REGISTRATION`: 300 points once per dog. Enter a 15-digit
  `registration_number`, or upload proof (including older/overseas chip formats).
  Whitespace and hyphens are removed from typed numbers; all remaining characters
  must be ASCII digits. Leading zeroes are preserved and no prefix is required.
  No registration dates are requested or inferred. New entitlements use the
  `microchip-lifetime-2026-09-25` rules version.
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

Each entitlement freezes its promised points and rules version. Hold/rejection
metadata can block collection without rewriting the original evidence or ledger.
Submissions include optional audit metadata and upload byte size; historical file
sizes remain unknown. The audit workflow is not enabled and no migrated submission
is marked verified.

Re-uploading preserves another version of the original entitlement and never
creates a second reward. Conflicting request-ID reuse returns 409. Per-dog file
fingerprints cannot support a different vet visit. A family certificate/photo can support
several dogs. Disabling Documents blocks new submissions and uncollected rewards
with 409; successful request/collection retries, history and downloads remain.

Historical microchip annual entitlements are retained unchanged. Lifetime
selection uses the oldest already-collected entitlement, or otherwise the oldest
pending entitlement, including any held/rejected reservation. Only that pending
entitlement may become collectible. The collect endpoint enforces this under the
dog lock, so multiple legacy periods cannot produce another credit. Existing
paid receipts continue to replay for their original recipients, with no points
removed. Superseded pending rows remain in document history with
`can_collect:false`, and are omitted from Quest tasks. Transfers do not reset the
lifetime limit; a new owner must submit evidence against an existing pending
entitlement before collecting it. An old microchip file can be attached to the
canonical entitlement without changing the historic file fingerprint or award.

`evidence.services.quest_tasks(owner=...,dogs=...,request=...,now=...)` returns
compact IN_PROGRESS, READY and COLLECTED task rows. Pending rewards suppress
additional tasks of that dog/type. COLLECTED tasks are shown only on their
collection's Melbourne date, while document history remains available. Former
owners see their evidence's dog-name snapshot, not the transferred dog's profile.

Registration submissions use exactly one path: manual details or a PDF/JPEG/PNG
proof upload. Uploads require no manually transcribed registration details or
dates. Both paths remain self-reported, with no government/database lookup or
automatic certificate verification. Historical exact request retries are checked
before new semantic rules, so previously accepted number-only or number-and-PDF
requests still replay their original receipts. New requests cannot reuse the old
validation rules.

JSON uploads are bounded at 4 MiB decoded and the request parser at 6 MiB. PDFs
must parse, have 1–20 pages and be unencrypted. All photos must decode as JPEG or
PNG and be at most 16 megapixels. Vet uploads remain photo-only. Files are not
OCR-checked. Submitted bytes remain
unchanged under generated names in `PRIVATE_MEDIA_ROOT`, never public
`MEDIA_ROOT`; the database and private files must be backed up together. Partial
write failures remove only the newly created file and database work rolls back.

`GET /api/quests/documents/{id}/file` permits only the submitting owner or an
admin (JWT, or an authenticated Django admin session). It returns an attachment
with private/no-store, nosniff and sandbox headers. The admin page is read-only;
original submissions cannot be overwritten or removed there. Deleting a dog
retains its name/ID snapshots, reward entitlement, ledger entry and evidence.
