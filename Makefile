VM ?=

.PHONY: ubuntu-pin up down destroy status ssh endpoints \
        provision-mongodb provision-postgres provision-nginx

ubuntu-pin:
	./scripts/ubuntu-pin.sh

up:
	./scripts/up.sh "$(VM)"

down:
	./scripts/down.sh "$(VM)"

destroy:
	./scripts/destroy.sh "$(VM)"

status:
	./scripts/status.sh "$(VM)"

ssh:
	./scripts/ssh.sh "$(VM)"

endpoints:
	./scripts/endpoints.sh "$(VM)"

provision-mongodb:
	./scripts/provision-mongodb.sh "$(VM)"

provision-postgres:
	./scripts/provision-postgres.sh "$(VM)"

provision-nginx:
	./scripts/provision-nginx.sh "$(VM)"
