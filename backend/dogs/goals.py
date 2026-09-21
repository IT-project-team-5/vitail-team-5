from dataclasses import asdict, dataclass
from typing import Literal

from .models import Dog


@dataclass(frozen=True)
class GoalResult:
    status: Literal["RULES_PENDING"]
    recommended_duration_minutes: None
    factors: dict
    unresolved_requirements: tuple[str, ...]


class DogGoalService:
    """Keeps goal inputs/API stable until the product team supplies numeric rules."""

    unresolved_requirements = (
        "Base duration by breed energy level",
        "Age threshold and senior-dog adjustment",
        "Size adjustment",
        "Brachycephalic adjustment",
        "Heat threshold, adjustment, and weather provider",
    )

    def calculate(self, dog: Dog) -> dict:
        result = GoalResult(
            status="RULES_PENDING",
            recommended_duration_minutes=None,
            factors={
                "breed_energy_level": dog.breed.energy_level,
                "age_months": dog.age_months,
                "size": dog.size,
                "is_brachycephalic": dog.is_brachycephalic,
            },
            unresolved_requirements=self.unresolved_requirements,
        )
        return asdict(result)
