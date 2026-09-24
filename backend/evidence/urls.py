from django.urls import re_path

from .views import DocumentCollectView, DocumentFileView, DocumentListCreateView

urlpatterns = [
    re_path(r"^quests/documents/?$", DocumentListCreateView.as_view(), name="documents"),
    re_path(r"^quests/documents/entitlements/(?P<entitlement_id>\d+)/collect/?$", DocumentCollectView.as_view(), name="document-collect"),
    re_path(r"^quests/documents/(?P<submission_id>\d+)/file/?$", DocumentFileView.as_view(), name="document-file"),
]
