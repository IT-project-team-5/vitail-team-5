import json
from functools import lru_cache
from pathlib import Path
import re

from rest_framework.exceptions import ValidationError


@lru_cache(maxsize=1)
def council_data():
    return json.loads(Path(__file__).with_name("councils.json").read_text(encoding="utf-8"))


def search_councils(query):
    query = query.strip()
    if any(char.isdigit() for char in query):
        if not re.fullmatch(r"[0-9]{4}", query):
            raise ValidationError("Enter a four-digit postcode or a Council name.")
        return [row for row in council_data() if query in row["postcodes"]]
    return [row for row in council_data() if query.casefold() in row["name"].casefold()] if query else []
