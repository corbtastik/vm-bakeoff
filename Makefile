PLATFORM ?= lima
VM_NAME  ?= ubuntu-todo-vz-$(PLATFORM)

CPUS     ?= 4
MEMORY   ?= 6GiB
HOST_HTTP?= 8080
HOST_API ?= 8081
DATA_DISK_NAME ?= ubuntu-todo-data-$(PLATFORM)
DATA_DISK_SIZE ?= 20GiB


LIMA_YAML := platforms/lima/lima.yaml

.PHONY: ubuntu-pin up down destroy status ssh endpoints provision

ubuntu-pin:
	./scripts/lima-pin-ubuntu.sh

up:
	./scripts/up.sh $(PLATFORM)

down:
	./scripts/down.sh $(PLATFORM)

destroy:
	./scripts/destroy.sh $(PLATFORM)

status:
	./scripts/status.sh $(PLATFORM)

ssh:
	./scripts/ssh.sh $(PLATFORM)

endpoints:
	./scripts/endpoints.sh $(PLATFORM)

provision:
	./scripts/provision.sh $(PLATFORM)
