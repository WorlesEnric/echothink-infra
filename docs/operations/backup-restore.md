# Backup and Restore Guide

This document covers backup strategies, restore procedures, and disaster recovery for every stateful component in the EchoThink infrastructure.

## Table of Contents

- [Backup Overview](#backup-overview)
- [PostgreSQL](#postgresql)
- [MinIO](#minio)
- [FalkorDB](#falkordb)
- [GitLab](#gitlab)
- [Redis](#redis)
- [Full Automated Backup](#full-automated-backup)
- [Restore Procedures](#restore-procedures)
- [Disaster Recovery Runbook](#disaster-recovery-runbook)
- [Backup Verification](#backup-verification)

---

## Backup Overview

| Component | Data at Risk | Backup Method | Frequency | Retention |
|-----------|-------------|---------------|-----------|-----------|
| PostgreSQL | All application databases | `pg_dump` per database | Every 6 hours | 30 days |
| MinIO | Artifacts, uploads, files | `mc mirror` | Daily | 14 days |
| FalkorDB | Knowledge graph | RDB snapshot copy | Daily | 14 days |
| GitLab | Repos, CI data, uploads | `gitlab-backup create` | Daily | 7 days |
| Redis | Cache only | Not backed up | N/A | N/A |

All backups should be stored on a separate volume or remote storage (S3-compatible, NFS, or rsync target). Never store backups on the same disk as the running services.

---

## PostgreSQL

PostgreSQL is the single most critical component. It stores data for: Authentik, Dify, Hatchet, Langfuse, LiteLLM, n8n, Outline, Supabase, and GitLab.

### Databases to back up

- `postgres` (shared, with pgvector extension)
- `authentik`
- `supabase`
- `dify`
- `hatchet`
- `langfuse`
- `litellm`
- `n8n`
- `outline`
- `gitlab`

### Manual backup

```bash
# Dump a single database (custom format, compressed)
docker exec echothink-postgres pg_dump \
  -U postgres \
  -Fc \
  --file=/tmp/authentik_backup.dump \
  authentik

# Copy the dump out of the container
docker cp echothink-postgres:/tmp/authentik_backup.dump ./backups/

# Dump all databases at once
for db in postgres authentik supabase dify hatchet langfuse litellm n8n outline gitlab; do
  docker exec echothink-postgres pg_dump \
    -U postgres \
    -Fc \
    --file=/tmp/${db}.dump \
    ${db} 2>/dev/null && \
  docker cp echothink-postgres:/tmp/${db}.dump ./backups/ && \
  echo "Backed up: ${db}"
done
```

### Scheduled backup with cron

Add this to the host's crontab (`crontab -e`):

```cron
# PostgreSQL backup every 6 hours
0 */6 * * * /path/to/echothink-infra/scripts/backup.sh /backups/echothink >> /var/log/echothink-backup.log 2>&1

# Cleanup backups older than 30 days
0 3 * * * find /backups/echothink -name "*.tar.gz" -mtime +30 -delete
```

### WAL archiving (advanced)

For point-in-time recovery, enable WAL archiving in `services/postgres/conf/postgresql.conf`:

```
wal_level = replica
archive_mode = on
archive_command = 'cp %p /backups/wal/%f'
```

This allows restoring to any point in time, not just the last dump.

---

## MinIO

MinIO stores all artifacts: agent-generated files, Supabase Storage objects, Dify workflow outputs, and user uploads.

### Manual backup

```bash
# Configure the mc client alias (run once)
docker exec echothink-minio mc alias set local http://localhost:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}

# Mirror all buckets to a backup location
docker exec echothink-minio mc mirror local/ /backup/minio/

# Or mirror to an external S3-compatible target
docker exec echothink-minio mc alias set backup https://backup-s3.example.com BACKUP_KEY BACKUP_SECRET
docker exec echothink-minio mc mirror local/ backup/echothink-mirror/
```

### Mirror from the host

```bash
# Install mc on the host
# https://min.io/docs/minio/linux/reference/minio-mc.html

mc alias set echothink http://localhost:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}
mc mirror echothink/ ./backups/minio/
```

### Incremental backup

`mc mirror` supports `--overwrite` and `--newer-than` flags for incremental copies:

```bash
mc mirror --newer-than "24h" echothink/ ./backups/minio/
```

---

## FalkorDB

FalkorDB (the knowledge graph database) uses Redis-compatible persistence. It writes RDB snapshots to disk.

### Manual backup

```bash
# Trigger an RDB save
docker exec echothink-falkordb redis-cli -p 6380 BGSAVE

# Wait for save to complete
docker exec echothink-falkordb redis-cli -p 6380 LASTSAVE

# Copy the dump file out
docker cp echothink-falkordb:/data/dump.rdb ./backups/falkordb_dump.rdb
```

### Persistence configuration

Ensure FalkorDB's Docker Compose volume maps `/data` to a host directory. The default RDB save policy writes snapshots periodically:

```
save 900 1      # Save after 900 seconds if at least 1 key changed
save 300 10     # Save after 300 seconds if at least 10 keys changed
save 60 10000   # Save after 60 seconds if at least 10000 keys changed
```

For stricter durability, enable AOF (append-only file) persistence in the FalkorDB configuration.

---

## GitLab

GitLab has its own backup utility that captures repositories, uploads, CI artifacts, database, and configuration.

### Manual backup

```bash
# Create a GitLab backup (this can take several minutes)
docker exec echothink-gitlab gitlab-backup create STRATEGY=copy

# The backup is written to /var/opt/gitlab/backups/ inside the container
docker cp echothink-gitlab:/var/opt/gitlab/backups/ ./backups/gitlab/

# Also back up the configuration secrets (critical for restore)
docker cp echothink-gitlab:/etc/gitlab/gitlab-secrets.json ./backups/gitlab/
docker cp echothink-gitlab:/etc/gitlab/gitlab.rb ./backups/gitlab/
```

### Scheduled GitLab backup

Add to crontab:

```cron
# GitLab backup daily at 2 AM
0 2 * * * docker exec echothink-gitlab gitlab-backup create STRATEGY=copy CRON=1 >> /var/log/gitlab-backup.log 2>&1
```

### Retention

Configure GitLab's built-in retention in `gitlab.rb`:

```ruby
gitlab_rails['backup_keep_time'] = 604800  # 7 days in seconds
```

---

## Redis

Redis is used exclusively as a cache and message broker in the EchoThink stack. All durable state is in PostgreSQL. Redis data loss is fully recoverable -- services will repopulate their caches on restart.

**No backup is required for Redis.**

If you want to preserve cache warmth across restarts, enable RDB persistence in the Redis configuration, but this is optional.

---

## Full Automated Backup

Use the provided backup script for a complete backup of all stateful services:

```bash
# Full backup with default directory (./backups/YYYYMMDD_HHMMSS)
./scripts/backup.sh

# Full backup to a specific directory
./scripts/backup.sh /mnt/backup-volume/echothink

# The script will:
# 1. Dump all PostgreSQL databases
# 2. Mirror all MinIO buckets
# 3. Copy FalkorDB persistence files
# 4. Compress everything into a single .tar.gz
# 5. Print a summary with sizes
```

### Recommended cron schedule

```cron
# Full backup daily at 1 AM
0 1 * * * /path/to/echothink-infra/scripts/backup.sh /backups/echothink >> /var/log/echothink-backup.log 2>&1

# PostgreSQL-only backup every 6 hours (lightweight)
0 */6 * * * /path/to/echothink-infra/scripts/backup.sh --pg-only /backups/echothink >> /var/log/echothink-backup.log 2>&1

# Cleanup old backups
0 4 * * * find /backups/echothink -name "*.tar.gz" -mtime +30 -delete
```

---

## Restore Procedures

### PostgreSQL Restore

```bash
# Restore a single database from custom-format dump
docker cp ./backups/authentik.dump echothink-postgres:/tmp/authentik.dump

# Drop and recreate the database (WARNING: destroys existing data)
docker exec echothink-postgres psql -U postgres -c "DROP DATABASE IF EXISTS authentik;"
docker exec echothink-postgres psql -U postgres -c "CREATE DATABASE authentik;"

# Restore the dump
docker exec echothink-postgres pg_restore \
  -U postgres \
  -d authentik \
  --no-owner \
  --no-privileges \
  /tmp/authentik.dump

# Restore all databases
for db in postgres authentik supabase dify hatchet langfuse litellm n8n outline gitlab; do
  if [ -f "./backups/${db}.dump" ]; then
    docker cp ./backups/${db}.dump echothink-postgres:/tmp/${db}.dump
    if [ "$db" != "postgres" ]; then
      docker exec echothink-postgres psql -U postgres -c "DROP DATABASE IF EXISTS ${db};"
      docker exec echothink-postgres psql -U postgres -c "CREATE DATABASE ${db};"
    fi
    docker exec echothink-postgres pg_restore \
      -U postgres \
      -d ${db} \
      --no-owner \
      --no-privileges \
      /tmp/${db}.dump
    echo "Restored: ${db}"
  fi
done

# Re-run extension initialization
docker exec echothink-postgres psql -U postgres -f /docker-entrypoint-initdb.d/00-extensions.sql
```

### MinIO Restore

```bash
# Restore from a local backup directory
mc alias set echothink http://localhost:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}
mc mirror ./backups/minio/ echothink/

# Or restore from a remote S3 backup
mc alias set backup https://backup-s3.example.com BACKUP_KEY BACKUP_SECRET
mc mirror backup/echothink-mirror/ echothink/
```

### FalkorDB Restore

```bash
# Stop FalkorDB
docker stop echothink-falkordb

# Replace the RDB file with the backup
docker cp ./backups/falkordb_dump.rdb echothink-falkordb:/data/dump.rdb

# Restart FalkorDB -- it will load the RDB on startup
docker start echothink-falkordb

# Verify the graph is loaded
docker exec echothink-falkordb redis-cli -p 6380 GRAPH.LIST
```

### GitLab Restore

```bash
# Stop GitLab services that connect to the database
docker exec echothink-gitlab gitlab-ctl stop puma
docker exec echothink-gitlab gitlab-ctl stop sidekiq

# Verify services are stopped
docker exec echothink-gitlab gitlab-ctl status

# Restore configuration secrets first
docker cp ./backups/gitlab/gitlab-secrets.json echothink-gitlab:/etc/gitlab/gitlab-secrets.json
docker cp ./backups/gitlab/gitlab.rb echothink-gitlab:/etc/gitlab/gitlab.rb

# Reconfigure GitLab with the restored config
docker exec echothink-gitlab gitlab-ctl reconfigure

# Restore the backup (use the timestamp from the backup filename)
docker exec echothink-gitlab gitlab-backup restore BACKUP=<timestamp>

# Restart GitLab
docker restart echothink-gitlab

# Check GitLab health
docker exec echothink-gitlab gitlab-rake gitlab:check SANITIZE=true
```

---

## Disaster Recovery Runbook

### Scenario: Complete host failure

**Recovery time objective (RTO):** 1 hour
**Recovery point objective (RPO):** 6 hours (last PostgreSQL backup)

#### Steps:

1. **Provision a new host** with Docker and Docker Compose installed.

2. **Clone the echothink-infra repository** to the new host.

3. **Restore the `.env` file** from secure storage (Vault, encrypted backup, etc.). Never store `.env` in backups alongside data dumps.

4. **Start the infrastructure services first** (PostgreSQL, Redis, MinIO):
   ```bash
   docker compose up -d postgres redis minio
   ```

5. **Wait for PostgreSQL to be healthy**, then restore all databases:
   ```bash
   # Copy backup archive to the host and extract
   tar -xzf echothink_backup_YYYYMMDD_HHMMSS.tar.gz -C /tmp/restore/

   # Restore each database
   for db in postgres authentik supabase dify hatchet langfuse litellm n8n outline gitlab; do
     docker cp /tmp/restore/pg/${db}.dump echothink-postgres:/tmp/${db}.dump
     if [ "$db" != "postgres" ]; then
       docker exec echothink-postgres psql -U postgres -c "DROP DATABASE IF EXISTS ${db};"
       docker exec echothink-postgres psql -U postgres -c "CREATE DATABASE ${db};"
     fi
     docker exec echothink-postgres pg_restore \
       -U postgres -d ${db} --no-owner --no-privileges /tmp/${db}.dump 2>/dev/null
   done
   ```

6. **Restore MinIO data:**
   ```bash
   mc mirror /tmp/restore/minio/ echothink/
   ```

7. **Restore FalkorDB:**
   ```bash
   docker cp /tmp/restore/falkordb/dump.rdb echothink-falkordb:/data/dump.rdb
   docker restart echothink-falkordb
   ```

8. **Start all remaining services:**
   ```bash
   docker compose up -d
   ```

9. **Run the health check script** to verify all services are operational:
   ```bash
   ./scripts/healthcheck.sh
   ```

10. **Verify Authentik SSO** -- log into the admin panel and confirm providers are functional.

11. **Verify Supabase Realtime** -- confirm WebSocket channels are accepting connections.

12. **Restore GitLab** (if applicable) following the GitLab Restore procedure above.

13. **Update DNS records** if the new host has a different IP address.

### Scenario: Single database corruption

1. Identify the corrupted database.
2. Stop the affected service (e.g., `docker compose stop dify`).
3. Restore only that database from the latest backup.
4. Restart the affected service.
5. Run the health check to verify.

### Scenario: MinIO data loss

1. MinIO data is replaceable from agent re-execution in many cases.
2. If backups exist, restore with `mc mirror`.
3. If no backup exists, recreate the required buckets and notify users that historical artifacts are unavailable.

---

## Backup Verification

Backups are only useful if they can be restored. Verify backups regularly.

### Weekly verification checklist

1. **Pick a random backup archive** from the last 7 days.

2. **Extract and inspect** the archive:
   ```bash
   tar -tzf echothink_backup_YYYYMMDD_HHMMSS.tar.gz
   ```

3. **Verify PostgreSQL dumps are valid** (does not require a running database):
   ```bash
   for dump in backups/pg/*.dump; do
     pg_restore --list "$dump" > /dev/null 2>&1 && echo "OK: $dump" || echo "CORRUPT: $dump"
   done
   ```

4. **Verify FalkorDB RDB is valid:**
   ```bash
   redis-check-rdb backups/falkordb/dump.rdb
   ```

5. **Spot-check MinIO files** -- verify a few files from each bucket are present and non-zero size.

6. **Test a full restore on a staging host** at least once per month. Spin up the full stack from a backup and confirm all services pass health checks.

### Automated verification

Add to cron (runs on the first Sunday of each month):

```cron
0 5 1-7 * 0 /path/to/echothink-infra/scripts/backup.sh --verify /backups/echothink/latest >> /var/log/echothink-backup-verify.log 2>&1
```
