def register_microchip(owner, dog):
    """Accepted self-report fixture; deliberately leave its reward uncollected."""
    from uuid import uuid4
    from evidence.serializers import DocumentRequestSerializer
    from evidence.services import submit_document
    data = DocumentRequestSerializer(data={"request_id": str(uuid4()), "dog_id": dog.pk,
        "kind": "MICROCHIP_REGISTRATION", "registration_number": "012345678901234"}, context={"owner": owner})
    data.is_valid(raise_exception=True)
    return submit_document(owner=owner, data=data.validated_data)
