"""Generate the ERD source and a compact SVG overview from the local DBML.

No third-party dependencies. This checks names/FK targets and coverage counts;
it is not a MySQL migration or a substitute for a DBML compiler.
"""
from pathlib import Path
import html
import re

ROOT = Path(__file__).resolve().parent
source = (ROOT / "schema.dbml").read_text()
tables = {}
for match in re.finditer(r"^Table (\w+) \{\n(.*?)^\}", source, re.M | re.S):
    name, body = match.groups()
    fields = []
    for line in body.splitlines():
        field = re.match(r"^  (\w+) ([\w]+(?:\([\d,]+\))?)(?: \[(.*)\])?$", line)
        if field:
            field_name, kind, flags = field.groups()
            fields.append((field_name, kind, flags or ""))
    tables[name] = fields
assert len(tables) == 28, f"Expected 28 tables, got {len(tables)}"
deferred = {"ExternalIdentity", "ChatMessage", "Charity", "Donation", "PushDevice", "NotificationDelivery"}
assert len(set(tables) - deferred) == 22
relations = []
for name, fields in tables.items():
    assert len(fields) == len({f[0] for f in fields}), name
    assert any("pk" in flags.split(", ") for _, _, flags in fields), name
    for field, kind, flags in fields:
        ref = re.search(r"ref: ([>\-]) (\w+)\.(\w+)", flags)
        if ref:
            direction, target, target_field = ref.groups()
            assert target in tables, (name, field, target)
            assert target_field in {f[0] for f in tables[target]}, (name, field, target_field)
            relations.append((name, field, target, "not null" in flags or "pk" in flags, direction == "-"))

mermaid = ["%% Generated from schema.dbml by render.py. Selected fields; DBML contains complete dictionary.", "erDiagram"]
for name, fields in tables.items():
    mermaid.append(f"    {name} {{")
    for field, kind, flags in fields:
        # Show keys and selected state/time/rule fields so the ERD remains navigable.
        if not ("pk" in flags or "ref:" in flags or "unique" in flags or field in {
            "kind", "status", "state", "local_date", "point_date", "amount", "remaining_points",
            "earned_on", "earn_category", "collected_at", "qualification_key", "entitlement_key",
            "target_active_seconds", "final_goal_met", "verified_seconds", "required_seconds",
            "category_slot", "rules_version", "date_of_birth", "microchip_number", "point_cost",
            "active_seconds", "distance_m", "net_distance_m", "started_at", "ended_at",
        }):
            continue
        keys = []
        if "pk" in flags: keys.append("PK")
        if "ref:" in flags: keys.append("FK")
        if "unique" in flags: keys.append("UK")
        type_name = re.sub(r"\(.*", "", kind)
        optional = "nullable" if "not null" not in flags and "pk" not in flags else "required"
        mermaid.append(f'        {type_name} {field}{" " + ",".join(keys) if keys else ""} "{optional}"')
    mermaid.append("    }")
for child, field, parent, required, one in relations:
    left = "||" if required else "|o"
    right = "o|" if one else "o{"
    mermaid.append(f'    {parent} {left}--{right} {child} : "{field}"')
(ROOT / "schema.mmd").write_text("\n".join(mermaid) + "\n")

groups = [
    ("IDENTITY", "People & dogs", ["User", "Breed", "Dog", "ExternalIdentity"], "#256b68", "Photos / birthday / microchip / consent"),
    ("COMMERCE", "Places & points", ["Venue", "Reward", "Redemption", "PointEntry", "CafeOrderFeedState"], "#956122", "One wallet ledger. One order model."),
    ("ACTIVITY", "Walks & verification", ["Walk", "WalkDog", "WalkSession", "LocationSample", "NetWalkInterval"], "#3c659b", "Summary history + short-lived GPS evidence"),
    ("QUESTS", "Goals & collection", ["DogDailyGoal", "QuestDefinition", "QuestAward", "CheckIn", "DocumentEntitlement", "DocumentSubmission", "EvidenceFingerprint"], "#795f92", "Eligibility and collection are distinct."),
    ("SOCIAL", "Friends & live map", ["Friendship", "UserBlock", "ChatMessage"], "#477c53", "Leaderboard is a query, not a table."),
    ("LATER", "Donations & notifications", ["Charity", "Donation", "PushDevice", "NotificationDelivery"], "#74747c", "Add with their feature. No payments."),
]
assert {t for _, _, names, _, _ in groups for t in names} == set(tables)
W, H = 1360, 1080
out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-labelledby="title desc">',
       '<title id="title">Vitail database design overview</title><desc id="desc">28 domain tables in six groups. 22 core tables and six deferred tables. Exact foreign keys are in schema.mmd and schema.dbml. Proposed design, not deployed.</desc>',
       '<rect width="100%" height="100%" fill="#f6f5f1"/>',
       '<g font-family="Arial,Helvetica,sans-serif">']
def text(x, y, value, size=16, fill="#263833", extra=""):
    return f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" {extra}>{html.escape(value)}</text>'
out += [text(56, 53, "VITAIL / DATA DESIGN", 14, "#64726b", 'letter-spacing="2"'),
        text(56, 105, "Complete coverage. Small, explicit models.", 36, extra='font-weight="700"'),
        text(56, 141, "22 core tables + 6 deferred  /  37 Jira items reviewed  /  25 September 2026", 18, "#64726b")]
for index, (label, title, names, color, subtitle) in enumerate(groups):
    col, row = index % 3, index // 3
    x, y, w, h = 56 + col * 430, 186 + row * 382, 390, 342
    out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="white" stroke="#d9ddd5"/>')
    out.append(f'<rect x="{x}" y="{y}" width="{w}" height="8" rx="4" fill="{color}"/>')
    out += [text(x+22, y+36, label, 12, color, 'letter-spacing="1.7" font-weight="700"'),
            text(x+22, y+68, title, 24, extra='font-weight="700"')]
    for i, name in enumerate(names):
        yy = y + 104 + i * 27
        out.append(text(x+22, yy, name, 17))
        if name in deferred:
            out.append(text(x+w-22, yy, "LATER", 10, "#777", 'text-anchor="end" letter-spacing="1"'))
    out.append(text(x+22, y+h-22, subtitle, 13, "#6f786f"))
out += [text(56, 967, "Key relationships", 16, extra='font-weight="700"'),
        text(56, 997, "User → Dog / Walk / Friendship     Venue → Reward → Redemption     Qualification → PointEntry", 16),
        text(56, 1038, "Overview only · Exact FK cardinalities and constraints: schema.mmd / schema.dbml · Design proposal, not a migration", 14, "#69786f"),
        '</g></svg>']
(ROOT / "overview.svg").write_text("\n".join(out))

coverage = (ROOT / "coverage.md").read_text()
issue_rows = re.findall(r"^\| \[SCRUM-(\d+)\]", coverage, re.M)
story_rows = re.findall(r"^\| US-(\d+)", coverage, re.M)
assert len(issue_rows) == len(set(issue_rows)) == 37
assert len(story_rows) == len(set(story_rows)) == 14
print(f"Validated {len(tables)} table names, {len(relations)} FK targets, 37 Jira rows, 14 story rows.")
print("Generated schema.mmd and overview.svg. Logical checks only; no database was contacted.")
