.PHONY: up down test check migrate superuser expire ios

up:
	docker compose up --build

down:
	docker compose down

test:
	docker compose run --rm --no-deps -e DATABASE_ENGINE=sqlite api python manage.py test

check:
	docker compose run --rm --no-deps -e DATABASE_ENGINE=sqlite api python manage.py check
	docker compose run --rm --no-deps -e DATABASE_ENGINE=sqlite api python manage.py makemigrations --check --dry-run

migrate:
	docker compose run --rm api python manage.py migrate

superuser:
	docker compose run --rm api python manage.py createsuperuser

expire:
	docker compose exec api python manage.py expire_rewards

ios:
	open ios/Vitail.xcodeproj
