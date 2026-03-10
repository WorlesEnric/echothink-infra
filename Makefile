.PHONY: init up up-all down down-all restart logs ps shell-db backup restore pull build clean healthcheck

COMPOSE = docker compose --env-file .env
CORE_FILES = -f docker-compose.yml
ALL_FILES = -f docker-compose.yml -f docker-compose.apps.yml

# Initialize the project: generate .env, secrets, and SSL certs
init:
	@bash scripts/init.sh

# Start core infrastructure only (postgres, redis, minio, nginx)
up:
	$(COMPOSE) $(CORE_FILES) up -d

# Start all services (core + applications)
up-all:
	$(COMPOSE) $(ALL_FILES) up -d

# Stop core infrastructure
down:
	$(COMPOSE) $(CORE_FILES) down

# Stop all services
down-all:
	$(COMPOSE) $(ALL_FILES) down

# Restart all services (or a specific service: make restart s=postgres)
restart:
ifdef s
	$(COMPOSE) $(ALL_FILES) restart $(s)
else
	$(COMPOSE) $(ALL_FILES) restart
endif

# Tail logs (or a specific service: make logs s=postgres)
logs:
ifdef s
	$(COMPOSE) $(ALL_FILES) logs -f $(s)
else
	$(COMPOSE) $(ALL_FILES) logs -f
endif

# Show running containers
ps:
	$(COMPOSE) $(ALL_FILES) ps

# Open a psql shell to the database
shell-db:
	$(COMPOSE) $(CORE_FILES) exec postgres psql -U postgres

# Run health checks on all services
healthcheck:
	@bash scripts/healthcheck.sh

# Backup all databases and object storage
backup:
	@bash scripts/backup.sh

# Restore from a backup file (usage: make restore f=backups/20240101_120000)
restore:
ifndef f
	@echo "Usage: make restore f=backups/YYYYMMDD_HHMMSS"
	@exit 1
endif
	@echo "Restoring from $(f)..."
	@bash scripts/backup.sh --restore $(f)

# Pull latest images
pull:
	$(COMPOSE) $(ALL_FILES) pull

# Build custom images (postgres, litellm)
build:
	$(COMPOSE) $(ALL_FILES) build

# Remove all containers, volumes, and networks
clean:
	@echo "WARNING: This will remove ALL containers, volumes, and data."
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	$(COMPOSE) $(ALL_FILES) down -v --remove-orphans
	@echo "Clean complete."
