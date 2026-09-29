# Self-reported document rewards

`GET /api/quests/documents` returns the owner's dogs, immutable submissions,
current eligibility, entitlements and two `registrations` management records per owned dog (Council/microchip). `POST` submits evidence and reserves a
reward; it awards **zero points**. `POST /api/quests/documents/entitlements/{id}/collect`
credits the reserved reward exactly once. Evidence stays `SELF_REPORTED` until
an actual audit; text recognition is not registration or authenticity verification.

## Submission fields

Every request includes `request_id` (UUID), `dog_id` and `kind`.

| Kind | Required confirmed details | Reward |
| --- | --- | --- |
| `COUNCIL_REGISTRATION` | `registration_number`, `council_name`, actual printed `valid_to` | 300 per current qualification; renew after expiry |
| `MICROCHIP_REGISTRATION` | `registration_number`; optional `registry_name` | 300 once per dog |
| `VET_CHECKUP` | `event_date` and JPEG/PNG evidence | 200, twice per calendar year, visits at least 60 days apart |

Council and microchip default to file upload in iOS. Both upload and manual
entry require confirmed details. Manual Council references allow ASCII letters,
digits, spaces and hyphens, at least one letter/digit, up to 100 characters.
Manual microchip numbers normalize whitespace/hyphens to exactly 15 ASCII digits.
Leading zeroes are preserved. File-backed references may use older or overseas
formats, with printable identifiers up to 100 characters. Microchip has no expiry.
`document_dog_name` optionally records the printed name separately from the app's
immutable `dog_name_snapshot`; submission never overwrites the dog's chip number.

New requests do not accept `registration_year` or `valid_from`; these remain
historical storage/output fields. `event_date` is for vet only. All dates use
YYYY-MM-DD. Vet dates cannot be future or before a known birthday.

## Council expiry and legacy records

`valid_to` is inclusive in Australia/Melbourne. A document valid through
15 June is current until midnight starting 16 June. No fixed 10 April reset,
upload-date anniversary or expiry inferred from a legacy year is used.

The normal submission endpoint cannot change an active entitlement's confirmed expiry; use the correction endpoint below.
Updated evidence attaches to the same reward. Once expired, a fresh current
registration creates a new entitlement (`expiry:YYYY-MM-DD`); the Animal ID may
stay the same. The same file cannot support another Council qualification for
that dog, including across ownership transfers.

Expired and superseded uncollected Council rewards are absent from Quest and
cannot be collected. History returns `EXPIRED`. Original files, submissions,
receipt snapshots and ledger entries remain intact. A previous paid reward can
still replay to its original recipient without another credit.

The newest paid Council qualification by creation order blocks another reward
until its renewal boundary passes (normally the confirmed expiry). Then only a newer pending qualification, if any,
is current. Without paid history, only the latest pending qualification is current.
This prevents legacy pending rows from becoming extra rewards.

A current legacy qualification with unknown expiry must be updated first:
`needs_expiry:true` creates an `IN_PROGRESS` task, worth zero new points if already
paid. Its expiry can be bound once, including a past expiry that retires it. This
updates the existing entitlement without modifying its original receipt or ledger.
The submission can send `expected_entitlement_id` from the Quest route; a changed
or expired route returns 409 rather than updating a different qualification.

Migration `0006` removes obsolete annual constraints and adds reading metadata.
It preserves existing values, including historical years, and never invents dates.

## Editing from dog settings

Account → dog → Registration documents shows the latest Council and lifetime
microchip record, including paid or expired records that no longer appear in Quest.
The user can view the private attachment, edit confirmed details, or replace the file.
Council renewal is a separate action when eligible. Vet evidence is unchanged.

`POST /api/quests/documents/{submission_id}/corrections` accepts the same confirmed
fields and a new request UUID. It requires the current owner and the latest version
of the selected qualification. A stale version returns 409; another owner's version
returns 404. An exact retry replays its original receipt. The operation and base ID
are included in the request fingerprint, preventing retries from switching routes.
The receipt adds `corrects_submission_id`; `awarded_points` is always zero.

A correction keeps the same entitlement, collection and ledger. Without a new file,
it reuses the previous file and reading metadata; a new upload is read and confirmed
again. Saved proof supports legacy identifier formats. Original submissions, files
and receipts remain unchanged. The app displays the latest version, not a history list.
The dog's separate profile chip number is not overwritten automatically.

Council `valid_to` is editable, including an actual past expiry. To prevent changing
an expiry from reopening the same reward, `renewal_blocked_through` retains the
latest confirmed expiry reached by that qualification. It never moves earlier.
For example, correcting 15 June to 1 June shows the document as expired after 1 June,
but the next renewal reward still opens on 16 June. Extending to 30 June postpones
renewal to 1 July. Settings separately shows expiry and `renewal_after` (inclusive
boundary); an expired pending reward cannot collect during the intervening period.
A correction after expiry still updates the old qualification with no new award;
use **Submit renewed registration** to reserve the next eligible reward.

Management is available even if the Documents quest is disabled; collection still
requires it to be enabled. The current owner never receives a former owner's private
submission in `registrations`. Migration `0007` initializes the boundary from known
Council expiry only, preserving unknown dates, receipts, files and point balances.

## Document reading

The iOS production reader uses PDFKit text first, then Apple Vision for scanned
PDF pages, missing fields and JPEG/PNG images. Reading is local, bounded and
cancellable. Labelled identifiers and expiry dates become suggestions; unrelated,
ambiguous or low-confidence values remain unresolved. Application/renewal forms
are not autofilled as completed certificates. The user confirms/corrects details
before submitting; an unreadable date never becomes today's date or 9 April.

Optional `document_reading` stores only bounded suggestions separately from
confirmed fields:

```json
{"source":"MIXED","pages_read":2,"candidates":{"valid_to":[{"value":"2027-06-15","page":2,"source":"APPLE_VISION"}]}}
```

Source is `PDF_TEXT`, `APPLE_VISION` or `MIXED`; pages are 1–20. Candidate keys are
`registration_number`, `council_name`, `registry_name`, `document_dog_name`,
`valid_to`, at most three each. Each has printable `value` (1–100 characters),
`page` within the file and optional `source` (`PDF_TEXT`/`APPLE_VISION`). Unknown
keys, raw OCR text and metadata without the original upload are rejected.
This is client-supplied provenance, not trusted verification.

## Collection, retries and privacy

Collection locks owner, dog and entitlement before crediting the canonical ledger.
Uncollected rewards require the current owner to have submitted evidence. Transfer
never resets quota. Only the original point recipient may replay a credited reward.
`EXPIRY_REQUIRED` and `EXPIRED` collection errors are HTTP 400; changed request IDs
or stale expected entitlement IDs return 409. Holds/rejections prevent collection.

Retry the exact owner/request UUID payload after ambiguous network failure.
Accepted requests replay their original receipt and balance, including historical
payload formats, even after expiry or collection. New UUIDs use current validation.
Disabled Documents blocks new submissions and collections, but not successful
retries, history or authorized downloads. Document bonuses do not use the daily cap.

Historical microchip rewards remain intact. The oldest paid entitlement, otherwise
the oldest pending entitlement, is canonical for the dog's lifetime. Superseded
pending rows cannot collect and never appear in Quest. Vet reservations consume
quota, including pending visits, and the 60-day separation crosses New Year.

Council task IDs are `council:{dog_id}:new` or
`council:{dog_id}:entitlement:{id}`. Tasks carry `valid_to` and `needs_expiry`;
collected tasks appear only on their collection's Melbourne day while still current.
History remains available separately. Former owners see their submission name
snapshot, not the transferred dog's current profile.

JSON requests are bounded at 6 MiB and decoded files at 4 MiB. PDFs must be
unencrypted, parseable and 1–20 pages. Images must decode as JPEG/PNG and contain
at most 16 megapixels. Files stay unchanged under generated names in
`PRIVATE_MEDIA_ROOT`. Back up database and private files together. Failed writes
remove only the new file and roll back database work.

`GET /api/quests/documents/{id}/file` permits the submitting owner or an admin
(JWT or Django admin session), with private/no-store, nosniff and sandbox headers.
The admin evidence view is read-only. Dog deletion preserves evidence, identity
snapshots, entitlements and points.
