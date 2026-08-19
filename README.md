# Vitail- Dog Walking Rewards

Android prototype where dog owners earn points from validated walks and spend those points at participating cafés.

## Product Roles

- **Owner:** register/login, manage dogs, track walks, view route, earn points, discover cafés, select items, generate QR, view balance/history.
- **Café:** self-register/login, edit café profile, manage items and availability, scan QR, confirm/reject redemption, view redemption history.
- **Admin:** use Django Admin for prototype management and support.

Owners and cafés use the **same Android app**. The backend account role determines which interface and APIs are available.

```text
OWNER → Owner UI
CAFE  → Café UI
ADMIN → Django Admin
```

## Core Rules

| Rule | Value |
|---|---|
| Walk reward | 1 point per valid walking minute |
| Minimum walk | 10 minutes |
| Daily earning cap | 300 points |
| Point expiry | Never |
| Dog multiplier | None |
| QR validity | 5 minutes |
| Café activation | Immediate after self-registration |

Approximate business guidance:

```text
20 points ≈ AUD 1
100 points ≈ AUD 5
```

Café items set their own point prices.

## Main User Flow

```text
Owner registers
→ adds dog
→ starts walk
→ route is tracked
→ walk syncs to backend
→ backend validates and awards points
→ owner finds café
→ selects items
→ generates QR
→ café scans and confirms
→ points are deducted exactly once
```

## Project Structure

Target layout. Only `README.md` and `TECH_STACK.md` exist today; the remaining
directories are created as each work stream begins.

```text
vitail-team-5/
├── android/            (planned)
├── backend/            (planned)
├── docs/               (planned)
├── docker-compose.yml  (planned)
├── README.md
└── TECH_STACK.md
```

## Team Ownership

Work is split by vertical use case.

| Engineer | Ownership |
|---|---|
| 1 | Accounts, profiles, dogs |
| 2 | Café registration, profile, items, café discovery |
| 3 | Walk tracking, offline sync, validation, points |
| 4 | Cart, QR, redemption, transaction history |

Each engineer owns the Android UI, API, database changes, tests, and documentation for their use case.

## Source of Truth

- `README.md` — product overview and locked rules
- `TECH_STACK.md` — detailed architecture and implementation conventions
- `docs/PROJECT_MAP.md` — detailed product behaviour (planned, not yet created)
- OpenAPI — API contract
- Django models + migrations — physical database structure

If code or AI-generated suggestions conflict with these documents, resolve the conflict before implementation.
