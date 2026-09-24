import os

from django.conf import settings
from django.core.files.storage import FileSystemStorage
from django.utils._os import safe_makedirs


class PrivateEvidenceStorage(FileSystemStorage):
    def __init__(self):
        super().__init__(file_permissions_mode=0o600, directory_permissions_mode=0o700)

    @property
    def base_location(self):
        return settings.PRIVATE_MEDIA_ROOT

    @property
    def location(self):
        return os.path.abspath(self.base_location)

    def url(self, name):
        raise ValueError("Evidence files require an authenticated download.")

    def _save(self, name, content):
        """Remove only this write's file if streaming fails after creation."""
        while True:
            full_path = self.path(name)
            safe_makedirs(os.path.dirname(full_path), self.directory_permissions_mode, exist_ok=True)
            try:
                descriptor = os.open(full_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, self.file_permissions_mode)
            except FileExistsError:
                name = self.get_available_name(name)
                continue
            break
        identity = os.fstat(descriptor)
        try:
            with os.fdopen(descriptor, "wb") as destination:
                for chunk in content.chunks():
                    destination.write(chunk)
            return name.replace("\\", "/")
        except BaseException:
            try:
                current = os.stat(full_path, follow_symlinks=False)
                if (current.st_dev, current.st_ino) == (identity.st_dev, identity.st_ino):
                    os.unlink(full_path)
            except FileNotFoundError:
                pass
            raise


private_storage = PrivateEvidenceStorage()
