from django.contrib import admin
from django.utils.html import format_html

from .models import DocumentSubmission


@admin.register(DocumentSubmission)
class DocumentSubmissionAdmin(admin.ModelAdmin):
    list_display = ("id", "owner", "dog_name_snapshot", "kind", "status", "awarded_points", "submitted_at")
    list_filter = ("kind", "status")
    search_fields = ("owner__email", "dog_name_snapshot", "registration_number")
    exclude = ("file", "response_snapshot")
    readonly_fields = tuple(field.name for field in DocumentSubmission._meta.fields if field.name not in {"file", "response_snapshot"}) + ("download",)

    @admin.display(description="Original evidence")
    def download(self, submission):
        if submission.file:
            return format_html('<a href="/api/quests/documents/{}/file">Download original evidence</a>', submission.pk)
        return "Registration number only"

    def has_add_permission(self, request):
        return False

    def has_delete_permission(self, request, obj=None):
        return False
