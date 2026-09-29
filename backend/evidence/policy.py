"""Council rewards follow the expiry confirmed from the registration document."""
from rewards.policy import local_date


def renewal_boundary(row):
    dates = [value for value in (row.valid_to, row.renewal_blocked_through) if value is not None]
    return max(dates) if dates else None


def council_entitlement(rows, today=None):
    """Keep the latest paid qualification blocking until its known expiry passes.

    Creation order represents the qualification; a late collection cannot turn
    an older document into the latest registration. Superseded pending records
    remain available as history, never as an additional claim.
    """
    today = today or local_date()
    rows = list(rows)
    order = lambda row: (row.created_at, row.pk)
    paid = max((row for row in rows if row.point_entry_id), key=order, default=None)
    if paid and (renewal_boundary(paid) is None or renewal_boundary(paid) >= today):
        return paid
    pending = [row for row in rows if not row.point_entry_id and (paid is None or order(row) > order(paid))]
    current = max(pending, key=order, default=None)
    return current if current and (renewal_boundary(current) is None or renewal_boundary(current) >= today) else None


def needs_expiry(row):
    return row.kind == "COUNCIL_REGISTRATION" and row.valid_to is None


def reward_status(row, today=None, *, canonical=True):
    if row.point_entry_id:
        return "COLLECTED"
    if row.kind == "COUNCIL_REGISTRATION":
        if not canonical or (row.valid_to and row.valid_to < (today or local_date())):
            return "EXPIRED"
        if row.valid_to is None:
            return "IN_PROGRESS"
    return "READY"
