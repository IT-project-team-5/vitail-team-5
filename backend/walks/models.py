from django.conf import settings
from django.db import models


class Walk(models.Model):
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name="walks"
    )
    request_id = models.UUIDField()
    request_fingerprint = models.CharField(max_length=64, editable=False)
    dogs = models.ManyToManyField("dogs.Dog", related_name="walks")
    started_at = models.DateTimeField()
    ended_at = models.DateTimeField()
    point_date = models.DateField()
    distance_m = models.DecimalField(max_digits=10, decimal_places=2)
    points_awarded = models.PositiveSmallIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ("-ended_at", "-id")
        constraints = [
            models.UniqueConstraint(
                fields=("owner", "request_id"), name="walk_owner_request_unique"
            ),
            models.CheckConstraint(
                condition=models.Q(ended_at__gt=models.F("started_at")),
                name="walk_end_after_start",
            ),
            models.CheckConstraint(
                condition=models.Q(distance_m__gte=0), name="walk_distance_nonnegative"
            ),
            models.CheckConstraint(
                condition=models.Q(points_awarded__lte=40), name="walk_points_at_most_40"
            ),
        ]

    def __str__(self):
        return f"{self.owner}: {self.distance_m} m, {self.points_awarded} points"
