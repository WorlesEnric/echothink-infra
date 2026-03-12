#!/usr/bin/env bash
#
# EchoThink Infrastructure Backup Script
#
# Creates a compressed backup of all stateful services:
#   - PostgreSQL (all databases via pg_dump)
#   - MinIO (all buckets via mc mirror)
#   - FalkorDB (RDB snapshot)
#
# Usage:
#   ./scripts/backup.sh [backup-directory]
#   ./scripts/backup.sh --pg-only [backup-directory]
#   ./scripts/backup.sh --verify <backup-archive>
#
# Examples:
#   ./scripts/backup.sh                              # Default: ./backups/YYYYMMDD_HHMMSS
#   ./scripts/backup.sh /mnt/backup/echothink        # Custom base directory
#   ./scripts/backup.sh --pg-only                     # PostgreSQL only
#   ./scripts/backup.sh --verify ./backups/backup.tar.gz  # Verify a backup archive
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

POSTGRES_CONTAINER="${ECHOTHINK_POSTGRES_CONTAINER:-echothink-postgres}"
REDIS_CONTAINER="${ECHOTHINK_REDIS_CONTAINER:-echothink-redis}"
FALKORDB_CONTAINER="${ECHOTHINK_FALKORDB_CONTAINER:-echothink-falkordb}"
MINIO_CONTAINER="${ECHOTHINK_MINIO_CONTAINER:-echothink-minio}"

POSTGRES_USER="${POSTGRES_USER:-postgres}"
FALKORDB_PORT="${FALKORDB_PORT:-6380}"

DATABASES=(postgres supabase dify hatchet langfuse litellm n8n outline gitlab)

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ---------------------------------------------------------------------------
# Color output
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

PG_ONLY=false
VERIFY_MODE=false
VERIFY_ARCHIVE=""
BACKUP_BASE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pg-only)
            PG_ONLY=true
            shift
            ;;
        --verify)
            VERIFY_MODE=true
            VERIFY_ARCHIVE="${2:-}"
            if [[ -z "$VERIFY_ARCHIVE" ]]; then
                error "Usage: $0 --verify <backup-archive>"
                exit 1
            fi
            shift 2
            ;;
        *)
            BACKUP_BASE="$1"
            shift
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Verify mode
# ---------------------------------------------------------------------------

verify_backup() {
    local archive="$1"

    if [[ ! -f "$archive" ]]; then
        error "Backup archive not found: $archive"
        exit 1
    fi

    echo -e "${BOLD}Verifying backup archive: $archive${NC}"
    echo ""

    # Check archive integrity
    info "Checking archive integrity..."
    if tar -tzf "$archive" > /dev/null 2>&1; then
        success "Archive is valid and readable"
    else
        error "Archive is corrupt or not a valid tar.gz file"
        exit 1
    fi

    # List contents
    info "Archive contents:"
    tar -tzf "$archive" | head -50
    local file_count
    file_count=$(tar -tzf "$archive" | wc -l | tr -d ' ')
    echo "  ... ($file_count files total)"
    echo ""

    # Check for PostgreSQL dumps
    info "Checking PostgreSQL dumps..."
    local pg_dumps
    pg_dumps=$(tar -tzf "$archive" | grep -c '\.dump$' || true)
    if [[ "$pg_dumps" -gt 0 ]]; then
        success "Found $pg_dumps PostgreSQL dump(s)"
        tar -tzf "$archive" | grep '\.dump$' | while read -r f; do
            echo "    - $f"
        done
    else
        warn "No PostgreSQL dumps found in archive"
    fi

    # Check for FalkorDB snapshot
    info "Checking FalkorDB snapshot..."
    if tar -tzf "$archive" | grep -q 'falkordb.*dump\.rdb'; then
        success "FalkorDB RDB snapshot found"
    else
        warn "No FalkorDB RDB snapshot found"
    fi

    # Check for MinIO data
    info "Checking MinIO data..."
    local minio_files
    minio_files=$(tar -tzf "$archive" | grep -c 'minio/' || true)
    if [[ "$minio_files" -gt 0 ]]; then
        success "Found $minio_files MinIO file(s)"
    else
        warn "No MinIO data found"
    fi

    # Archive size
    local size
    size=$(du -h "$archive" | cut -f1)
    echo ""
    success "Backup archive size: $size"
    echo ""
    echo -e "${GREEN}${BOLD}Verification complete.${NC}"
}

if [[ "$VERIFY_MODE" == true ]]; then
    verify_backup "$VERIFY_ARCHIVE"
    exit 0
fi

# ---------------------------------------------------------------------------
# Setup backup directory
# ---------------------------------------------------------------------------

if [[ -z "$BACKUP_BASE" ]]; then
    BACKUP_BASE="./backups"
fi

BACKUP_DIR="${BACKUP_BASE}/${TIMESTAMP}"
ARCHIVE_PATH="${BACKUP_BASE}/echothink_backup_${TIMESTAMP}.tar.gz"

mkdir -p "$BACKUP_DIR"

echo -e "${BOLD}EchoThink Infrastructure Backup${NC}"
echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo "Backup directory: $BACKUP_DIR"
echo ""

# Track timing
BACKUP_START=$(date +%s)

# ---------------------------------------------------------------------------
# PostgreSQL backup
# ---------------------------------------------------------------------------

backup_postgres() {
    info "Starting PostgreSQL backup..."
    mkdir -p "${BACKUP_DIR}/pg"

    local db_count=0
    local db_failed=0

    for db in "${DATABASES[@]}"; do
        info "  Dumping database: $db"

        # Check if database exists
        if ! docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$db"; then
            warn "  Database '$db' does not exist, skipping"
            continue
        fi

        # Create the dump inside the container
        if docker exec "$POSTGRES_CONTAINER" pg_dump \
            -U "$POSTGRES_USER" \
            -Fc \
            --file="/tmp/${db}.dump" \
            "$db" 2>/dev/null; then

            # Copy it out
            docker cp "${POSTGRES_CONTAINER}:/tmp/${db}.dump" "${BACKUP_DIR}/pg/${db}.dump" 2>/dev/null

            # Clean up inside container
            docker exec "$POSTGRES_CONTAINER" rm -f "/tmp/${db}.dump" 2>/dev/null

            local dump_size
            dump_size=$(du -h "${BACKUP_DIR}/pg/${db}.dump" 2>/dev/null | cut -f1)
            success "  $db: $dump_size"
            db_count=$((db_count + 1))
        else
            error "  Failed to dump database: $db"
            db_failed=$((db_failed + 1))
        fi
    done

    echo ""
    if [[ $db_failed -eq 0 ]]; then
        success "PostgreSQL backup complete: $db_count database(s) dumped"
    else
        warn "PostgreSQL backup complete: $db_count succeeded, $db_failed failed"
    fi
}

# ---------------------------------------------------------------------------
# MinIO backup
# ---------------------------------------------------------------------------

backup_minio() {
    info "Starting MinIO backup..."
    mkdir -p "${BACKUP_DIR}/minio"

    # Check if MinIO container is running
    if ! docker inspect --format='{{.State.Running}}' "$MINIO_CONTAINER" 2>/dev/null | grep -q "true"; then
        warn "MinIO container is not running, skipping MinIO backup"
        return
    fi

    # List all buckets
    local buckets
    buckets=$(docker exec "$MINIO_CONTAINER" mc ls local/ 2>/dev/null | awk '{print $NF}' | tr -d '/' || true)

    if [[ -z "$buckets" ]]; then
        warn "No MinIO buckets found or mc is not configured"
        return
    fi

    local bucket_count=0

    for bucket in $buckets; do
        info "  Mirroring bucket: $bucket"

        mkdir -p "${BACKUP_DIR}/minio/${bucket}"

        # Mirror the bucket contents to the backup directory
        # We use docker cp after mirroring inside the container
        if docker exec "$MINIO_CONTAINER" mc mirror --quiet "local/${bucket}" "/tmp/minio_backup_${bucket}" 2>/dev/null; then
            docker cp "${MINIO_CONTAINER}:/tmp/minio_backup_${bucket}/." "${BACKUP_DIR}/minio/${bucket}/" 2>/dev/null
            docker exec "$MINIO_CONTAINER" rm -rf "/tmp/minio_backup_${bucket}" 2>/dev/null

            local bucket_size
            bucket_size=$(du -sh "${BACKUP_DIR}/minio/${bucket}" 2>/dev/null | cut -f1)
            success "  $bucket: $bucket_size"
            bucket_count=$((bucket_count + 1))
        else
            # Fallback: try to copy via the host mc client
            if command -v mc &> /dev/null; then
                if mc mirror --quiet "echothink/${bucket}" "${BACKUP_DIR}/minio/${bucket}/" 2>/dev/null; then
                    local bucket_size
                    bucket_size=$(du -sh "${BACKUP_DIR}/minio/${bucket}" 2>/dev/null | cut -f1)
                    success "  $bucket: $bucket_size (via host mc)"
                    bucket_count=$((bucket_count + 1))
                else
                    warn "  Failed to mirror bucket: $bucket"
                fi
            else
                warn "  Failed to mirror bucket: $bucket (mc not available on host)"
            fi
        fi
    done

    echo ""
    success "MinIO backup complete: $bucket_count bucket(s) mirrored"
}

# ---------------------------------------------------------------------------
# FalkorDB backup
# ---------------------------------------------------------------------------

backup_falkordb() {
    info "Starting FalkorDB backup..."
    mkdir -p "${BACKUP_DIR}/falkordb"

    # Check if FalkorDB container is running
    if ! docker inspect --format='{{.State.Running}}' "$FALKORDB_CONTAINER" 2>/dev/null | grep -q "true"; then
        warn "FalkorDB container is not running, skipping FalkorDB backup"
        return
    fi

    # Trigger a background save
    info "  Triggering BGSAVE..."
    docker exec "$FALKORDB_CONTAINER" redis-cli -p "$FALKORDB_PORT" BGSAVE 2>/dev/null || true

    # Wait for the save to complete (max 60 seconds)
    local wait_count=0
    local max_wait=60
    while [[ $wait_count -lt $max_wait ]]; do
        local lastsave_before lastsave_after
        lastsave_after=$(docker exec "$FALKORDB_CONTAINER" redis-cli -p "$FALKORDB_PORT" LASTSAVE 2>/dev/null | tr -d '[:space:]')

        # Check if BGSAVE is still in progress
        local bgsave_status
        bgsave_status=$(docker exec "$FALKORDB_CONTAINER" redis-cli -p "$FALKORDB_PORT" INFO persistence 2>/dev/null | grep "rdb_bgsave_in_progress" | cut -d: -f2 | tr -d '[:space:]')

        if [[ "$bgsave_status" == "0" ]]; then
            break
        fi

        sleep 1
        wait_count=$((wait_count + 1))
    done

    if [[ $wait_count -ge $max_wait ]]; then
        warn "  BGSAVE did not complete within ${max_wait}s, copying current RDB file"
    else
        success "  BGSAVE completed"
    fi

    # Copy the RDB file out of the container
    if docker cp "${FALKORDB_CONTAINER}:/data/dump.rdb" "${BACKUP_DIR}/falkordb/dump.rdb" 2>/dev/null; then
        local rdb_size
        rdb_size=$(du -h "${BACKUP_DIR}/falkordb/dump.rdb" 2>/dev/null | cut -f1)
        success "FalkorDB backup complete: $rdb_size"
    else
        error "Failed to copy FalkorDB RDB file"
    fi
}

# ---------------------------------------------------------------------------
# Compress backup
# ---------------------------------------------------------------------------

compress_backup() {
    info "Compressing backup..."

    tar -czf "$ARCHIVE_PATH" -C "$BACKUP_BASE" "$TIMESTAMP"

    local archive_size
    archive_size=$(du -h "$ARCHIVE_PATH" | cut -f1)
    success "Compressed archive: $ARCHIVE_PATH ($archive_size)"

    # Remove the uncompressed directory
    rm -rf "$BACKUP_DIR"
    info "Removed uncompressed backup directory"
}

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------

print_summary() {
    local backup_end
    backup_end=$(date +%s)
    local duration=$((backup_end - BACKUP_START))

    echo ""
    echo -e "${BOLD}=== Backup Summary ===${NC}"
    echo "  Date:     $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Duration: ${duration}s"
    echo "  Archive:  $ARCHIVE_PATH"

    if [[ -f "$ARCHIVE_PATH" ]]; then
        local archive_size
        archive_size=$(du -h "$ARCHIVE_PATH" | cut -f1)
        echo "  Size:     $archive_size"
    fi

    echo ""

    # List contents of the archive
    if [[ -f "$ARCHIVE_PATH" ]]; then
        echo "  Contents:"
        local pg_count
        pg_count=$(tar -tzf "$ARCHIVE_PATH" | grep -c '\.dump$' || true)
        echo "    PostgreSQL databases: $pg_count"

        if [[ "$PG_ONLY" == false ]]; then
            local minio_count
            minio_count=$(tar -tzf "$ARCHIVE_PATH" | grep -c 'minio/' || true)
            echo "    MinIO files:          $minio_count"

            if tar -tzf "$ARCHIVE_PATH" | grep -q 'falkordb/dump.rdb'; then
                echo "    FalkorDB snapshot:    yes"
            else
                echo "    FalkorDB snapshot:    no"
            fi
        fi
    fi

    echo ""
    echo -e "${GREEN}${BOLD}Backup complete.${NC}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    # Always back up PostgreSQL
    backup_postgres

    # Back up other services unless --pg-only
    if [[ "$PG_ONLY" == false ]]; then
        echo ""
        backup_minio
        echo ""
        backup_falkordb
    fi

    echo ""
    compress_backup
    print_summary
}

main
