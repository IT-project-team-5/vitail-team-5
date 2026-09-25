from django.http import FileResponse, Http404
from rest_framework.authentication import SessionAuthentication
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework.exceptions import AuthenticationFailed

from accounts.authentication import AccountJWTAuthentication

from accounts.photos import photo_url
from dogs.models import Dog
from rewards.permissions import IsOwnerRole

from .models import DocumentSubmission
from .serializers import DocumentRequestSerializer, DocumentSubmissionSerializer
from .services import collect_document, eligibility_for, entitlements_for, submit_document
from .uploads import DocumentJSONParser


class DocumentListCreateView(APIView):
    permission_classes = [IsOwnerRole]
    parser_classes = [DocumentJSONParser]

    def get(self, request):
        dogs = list(Dog.objects.filter(owner=request.user))
        return Response({
            "dogs": [{"id": dog.pk, "name": dog.name,
                      "photo": photo_url(dog.uploaded_photo, request) if dog.uploaded_photo else dog.photo} for dog in dogs],
            "submissions": DocumentSubmissionSerializer(DocumentSubmission.objects.filter(owner=request.user).select_related("entitlement"), many=True).data,
            "eligibility": eligibility_for(request.user, dogs),
            "entitlements": entitlements_for(request.user),
        })

    def post(self, request):
        serializer = DocumentRequestSerializer(data=request.data, context={"owner": request.user})
        serializer.is_valid(raise_exception=True)
        receipt, created = submit_document(owner=request.user, data=serializer.validated_data)
        return Response(receipt, status=201 if created else 200)


class DocumentCollectView(APIView):
    permission_classes = [IsOwnerRole]

    def post(self, request, entitlement_id):
        return Response(collect_document(owner=request.user, entitlement_id=entitlement_id))


class DocumentFileView(APIView):
    authentication_classes = [AccountJWTAuthentication, SessionAuthentication]
    permission_classes = [IsAuthenticated]

    def get(self, request, submission_id):
        # Admin downloads also allow Django sessions. Those do not pass through
        # JWT account-version checks, so a tombstone must be denied here too.
        if request.user.deleted_at:
            raise AuthenticationFailed("This session has ended. Please sign in again.", code="session_revoked")
        submissions = DocumentSubmission.objects.all()
        if request.user.role != "ADMIN" and not request.user.is_superuser:
            submissions = submissions.filter(owner=request.user)
        submission = submissions.filter(pk=submission_id).first()
        if submission is None or not submission.file:
            raise Http404
        try:
            file = submission.file.open("rb")
        except FileNotFoundError as exc:
            raise Http404 from exc
        response = FileResponse(file, as_attachment=True, filename=submission.filename,
                                content_type=submission.file_content_type)
        response["Cache-Control"] = "private, no-store"
        response["X-Content-Type-Options"] = "nosniff"
        response["Content-Security-Policy"] = "sandbox; default-src 'none'"
        return response
