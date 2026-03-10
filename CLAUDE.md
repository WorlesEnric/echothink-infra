# CLAUDE.md -- EchoThink Infrastructure

## Project Overview

EchoThink is a self-hosted, open-source infrastructure stack for real-time human-AI collaboration. It enables small teams to work alongside fleets of AI agents as structured employees -- with identities, permissions, task assignments, and observable outputs.

This repository contains the Docker Compose services, Kubernetes manifests, Nginx configurations, and operational scripts that compose the full platform.

## Directory Structure

```
echothink-infra/
├── CLAUDE.md                  # This file -- project conventions for Claude Code
├── docs/
│   ├── open-source-stack-architecture.md   # Full architecture document
│   └── operations/
│       ├── backup-restore.md  # Backup and disaster recovery procedures
│       └── scaling-guide.md   # Per-service scaling guidance
├── k8s/
│   ├── helm/
│   │   └── echothink/
│   │       └── templates/     # Helm chart templates per service
│   └── kustomize/
│       ├── base/              # Base Kubernetes manifests
│       └── overlays/
│           ├── dev/           # Dev environment overrides
│           └── production/    # Production environment overrides
├── scripts/
│   ├── healthcheck.sh         # Service health verification script
│   └── backup.sh              # Automated backup script
└── services/
    ├── authentik/
    │   └── blueprints/        # Authentik flow and provider blueprints
    ├── dify/
    │   └── config/            # Dify configuration files
    ├── gitlab/                # GitLab EE configuration
    ├── graphiti/
    │   └── config/            # Graphiti + FalkorDB configuration
    ├── hatchet/
    │   └── config/            # Hatchet task engine configuration
    ├── langfuse/              # Langfuse observability configuration
    ├── litellm/               # LiteLLM gateway configuration
    ├── minio/                 # MinIO object storage configuration
    ├── n8n/                   # n8n automation configuration
    ├── nginx/
    │   ├── conf.d/            # Per-service Nginx virtual host configs
    │   └── ssl/               # TLS certificates
    ├── outline/               # Outline wiki configuration
    ├── postgres/
    │   ├── Dockerfile         # PostgreSQL 16 + pgvector image
    │   └── init/              # SQL init scripts (extensions, schemas)
    ├── redis/                 # Redis configuration
    └── supabase/
        ├── migrations/        # Supabase schema migrations
        └── volumes/           # Supabase volume mount configs
```

## How to Add a New Service

1. **Create the service directory**: `services/<service-name>/` with any config files.
2. **Create or update the Docker Compose file**: Add the service definition to `docker-compose.yml` (or `docker-compose.<service-name>.yml` if using split compose files). Attach it to the `echothink` network. Define a named volume following the convention below.
3. **Add Nginx configuration**: Create `services/nginx/conf.d/<service-name>.conf` with the reverse proxy block. Use the internal Docker DNS name as the upstream.
4. **Add Authentik provider**: Create an OAuth2/OpenID provider in Authentik for the service. Add the corresponding application and assign it to an authorization flow. Store the client ID and secret as env vars.
5. **Add environment variables**: Add all new env vars to `.env.example` with descriptive comments. Use the naming convention below.
6. **Add Kubernetes manifests**: Create a template directory under `k8s/helm/echothink/templates/<service-name>/` with Deployment, Service, ConfigMap, and optionally Ingress manifests. Add kustomize patches if needed.
7. **Update healthcheck script**: Add a health check entry to `scripts/healthcheck.sh`.
8. **Update backup script**: If the service has persistent data, add a backup step to `scripts/backup.sh`.

## Naming Conventions

### Service Names
- Docker Compose service names: lowercase, hyphenated (e.g., `litellm`, `falkordb`, `supabase-kong`)
- Container names: prefixed with `echothink-` (e.g., `echothink-postgres`, `echothink-redis`)

### Environment Variables
- Prefixed by service name in SCREAMING_SNAKE_CASE
- Database credentials: `<SERVICE>_DB_HOST`, `<SERVICE>_DB_PORT`, `<SERVICE>_DB_NAME`, `<SERVICE>_DB_USER`, `<SERVICE>_DB_PASSWORD`
- URLs: `<SERVICE>_URL`, `<SERVICE>_PUBLIC_URL`
- Secrets: `<SERVICE>_SECRET_KEY`, `<SERVICE>_API_KEY`
- Examples: `AUTHENTIK_SECRET_KEY`, `LITELLM_DB_NAME`, `MINIO_ROOT_USER`

### Database Names
- One database per service, named after the service: `authentik`, `dify`, `hatchet`, `langfuse`, `n8n`, `outline`, `supabase`, `litellm`, `gitlab`
- All databases live in the shared PostgreSQL 16 instance (with pgvector)
- Init scripts in `services/postgres/init/` create databases and extensions

### Volume Names
- Pattern: `echothink_<service>_data` (e.g., `echothink_postgres_data`, `echothink_minio_data`)

## Docker Compose Conventions

### Networks
- All services join the `echothink` bridge network
- Network name: `echothink_net`
- Services reference each other by Docker Compose service name as hostname

### Healthchecks
- Every service must define a `healthcheck` block in its compose definition
- HTTP services: `curl -f http://localhost:<port>/health || exit 1`
- PostgreSQL: `pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}`
- Redis: `redis-cli ping | grep -q PONG`
- FalkorDB: `redis-cli -p 6380 ping | grep -q PONG`
- MinIO: `curl -f http://localhost:9000/minio/health/live || exit 1`
- Interval: 30s, timeout: 10s, retries: 3, start_period: 30-60s depending on service

### Dependency Ordering
- Most services depend on `postgres` and `redis` with `condition: service_healthy`
- Supabase services depend on `supabase-db` (or the shared postgres) and `supabase-kong`
- Dify depends on `redis`, `postgres`, and `minio`
- Hatchet depends on `postgres` and `redis`
- Graphiti depends on `falkordb`

## Common Operations

```bash
# Start all core services
make up

# Stop all services
make down

# View logs for a specific service
make logs SERVICE=dify

# Restart a single service
make restart SERVICE=litellm

# Run health checks across all services
make healthcheck
# or directly:
./scripts/healthcheck.sh

# Create a full backup
make backup
# or directly:
./scripts/backup.sh [backup-directory]

# Restore from backup
./scripts/backup.sh --restore <backup-archive>

# Rebuild a single service image
make build SERVICE=postgres

# Run database migrations
make migrate

# Open a psql shell
make psql DB=authentik
```

## Key File Locations

| Purpose | Path |
|---------|------|
| Architecture document | `docs/open-source-stack-architecture.md` |
| Backup/restore guide | `docs/operations/backup-restore.md` |
| Scaling guide | `docs/operations/scaling-guide.md` |
| PostgreSQL Dockerfile | `services/postgres/Dockerfile` |
| PostgreSQL init SQL | `services/postgres/init/00-extensions.sql` |
| Nginx site configs | `services/nginx/conf.d/` |
| TLS certificates | `services/nginx/ssl/` |
| Authentik blueprints | `services/authentik/blueprints/` |
| Supabase migrations | `services/supabase/migrations/` |
| Helm chart | `k8s/helm/echothink/` |
| Kustomize overlays | `k8s/kustomize/overlays/` |
| Health check script | `scripts/healthcheck.sh` |
| Backup script | `scripts/backup.sh` |

## Testing and Verification

### After any infrastructure change:

1. **Run the health check script** to verify all services are responsive:
   ```bash
   ./scripts/healthcheck.sh
   ```

2. **Verify database connectivity** -- confirm each service database exists and has the expected extensions:
   ```bash
   docker exec echothink-postgres psql -U postgres -c "\l"
   docker exec echothink-postgres psql -U postgres -d postgres -c "\dx"
   ```

3. **Verify Nginx routing** -- each service should be reachable through its subdomain:
   ```bash
   curl -s -o /dev/null -w "%{http_code}" https://auth.echothink.local/
   curl -s -o /dev/null -w "%{http_code}" https://dify.echothink.local/
   curl -s -o /dev/null -w "%{http_code}" https://minio.echothink.local/
   ```

4. **Verify Authentik SSO** -- log into Authentik admin and confirm all providers and applications are listed.

5. **Verify Supabase Realtime** -- use the Supabase Studio dashboard to confirm Realtime channels are active.

6. **Verify MinIO buckets** -- confirm required buckets exist:
   ```bash
   docker exec echothink-minio mc ls local/
   ```

7. **Verify FalkorDB** -- confirm the graph database accepts queries:
   ```bash
   docker exec echothink-falkordb redis-cli -p 6380 GRAPH.QUERY echothink "RETURN 1"
   ```

### Before merging a PR:

- All health checks pass
- No new secrets committed to version control
- `.env.example` updated if new env vars were added
- Kubernetes manifests updated to match any Compose changes
- Documentation updated if operational procedures changed
