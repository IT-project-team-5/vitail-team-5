# Verification and review

The [Testing hub](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/13795332)
owns the plan, acceptance cases and actual run records. This page explains how
to reproduce engineering checks; it is not a record that every case passed.

## Local checks

`make check` and `make test` use isolated SQLite. They are useful quick checks,
but skip the MySQL row-lock tests. Use a disposable MySQL server for full
verification; never point tests or rehearsals at a shared or production database.

From `backend`, with a supported Python environment and the disposable MySQL
connection configured through the variables in `.env.example`:

```bash
mkdir -p ../test-results
python -m pip install -r requirements-test.txt
python manage.py check
python manage.py makemigrations --check --dry-run
python -m coverage run manage.py test --noinput --verbosity 2
python -m coverage report
python -m coverage json -o ../test-results/backend-coverage.json
python -m pip freeze --all > ../test-results/backend-dependencies.txt
```

Django creates and removes its separate `test_`
database; its MySQL user needs permission to do that. The coverage configuration
measures application Python, including admin and maintenance commands, and branch
outcomes. It excludes test code, migrations and startup wrappers. Migration checks
and upgrade/restore evidence are separate. No numerical coverage gate is implied.

For iOS, select the Vitail scheme and a simulator, then Product > Test. Use
`-enableCodeCoverage YES` when running `xcodebuild test` from the terminal and
keep the `.xcresult`. Report `Vitail.app` separately from the test target.
Location, locked-device storage and two-phone behavior need appropriate device
checks; a simulator skip is not a pass.

## CI evidence

The verification workflow runs MySQL and iOS tests on PRs and main. It records
source SHA, runtime, resolved Python packages, full logs, backend coverage and
Xcode result/summary/case/coverage files. New artifacts request 90-day retention,
subject to repository policy. Changing the workflow does not extend older
artifacts automatically.

A failed run remains evidence: keep its error and the correcting run. A later
passing result must identify the source and configuration it actually exercised.
Before a submission or handover, copy necessary evidence to the shared location
linked by the Testing hub and verify authorised-reader access. CI expiry and a
personal laptop must not be the only retention mechanism.

## Review checklist

A non-author teammate reviews the final change and its evidence before merge.
AI assistance is disclosed and does not replace that person's judgment. Check:

- The changed behavior matches the linked requirement and acceptance criteria.
- Names and structure fit existing code; errors and empty states are usable.
- Account boundaries, private data, retries and money/point changes are safe.
- Tests exercise the important success and failure cases; no unnecessary tests
  merely repeat the implementation.
- Migrations, API and affected instructions agree; no personal secrets or
  signing settings are committed.

CI checks changed-line whitespace. Other conventions above remain explicit
review responsibilities; no formatter or static-analysis gate is claimed.
Use the PR template to record actual findings, resolution and test limitations.
A green suite is not final client acceptance.
