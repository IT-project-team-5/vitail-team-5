# Profile photos

Account, dog and café photo endpoints accept authenticated JSON uploads. Uploads
must be JPEG, PNG or WebP, no more than 4 MiB decoded and 16 megapixels. The server
applies EXIF orientation, resizes to 1024 pixels per side, removes metadata and
stores a generated JPEG. User and café photos share the same account photo. A dog
upload takes precedence over its existing external `photo` URL, which remains
stored for backwards compatibility.

`MEDIA_ROOT` defaults to `backend/media/`. The existing Docker bind mount preserves
that directory when containers are rebuilt; include it alongside the database in
backups. It is excluded from Git. `DJANGO_MEDIA_ROOT` and `DJANGO_MEDIA_URL` can be
set for external storage or deployment. Django serves local media only with
`DEBUG=True`; a production web server or storage backend must serve the configured
media URL. Responses resolve photo URLs against the request host, so devices must
use the reachable backend address.

Photo uploads modify only the authenticated user's account or café, or a dog owned
by that user. Old uploaded files are deleted only after a replacement commits.
The schema migrations add optional fields and retain existing accounts, café
details, external dog photo URLs, balances and orders.
