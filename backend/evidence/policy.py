"""Registration reward periods use Melbourne's Victorian council year."""
from rewards.policy import local_date


def council_registration_year(day=None):
    day = day or local_date()
    return day.year + ((day.month, day.day) >= (4, 10))
