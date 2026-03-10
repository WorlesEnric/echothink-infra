#!/usr/bin/env bash
#
# EchoThink Infrastructure Health Check
#
# Checks all services and prints colored status output.
# Exit code 0 if all services are healthy, non-zero otherwise.
#
# Usage: ./scripts/healthcheck.sh [--quiet]
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

# Service URLs (accessible from the host)
NGINX_URL="${NGINX_URL:-http://localhost:80}"
AUTHENTIK_URL="${AUTHENTIK_URL:-http://localhost:9000}"
SUPABASE_KONG_URL="${SUPABASE_KONG_URL:-http://localhost:8000}"
LITELLM_URL="${LITELLM_URL:-http://localhost:4000}"
DIFY_URL="${DIFY_URL:-http://localhost:5001}"
HATCHET_URL="${HATCHET_URL:-http://localhost:7077}"
LANGFUSE_URL="${LANGFUSE_URL:-http://localhost:3000}"
N8N_URL="${N8N_URL:-http://localhost:5678}"
OUTLINE_URL="${OUTLINE_URL:-http://localhost:3001}"
GITLAB_URL="${GITLAB_URL:-http://localhost:8929}"

# Databases that should exist in PostgreSQL
DATABASES=(postgres authentik supabase dify hatchet langfuse litellm n8n outline gitlab)

# MinIO buckets that should exist
MINIO_BUCKETS=(artifacts uploads supabase)

# ---------------------------------------------------------------------------
# Color output
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

QUIET=false
if [[ "${1:-}" == "--quiet" ]]; then
    QUIET=true
fi

FAILED=0
PASSED=0
SKIPPED=0

print_header() {
    if [[ "$QUIET" == false ]]; then
        echo ""
        echo -e "${BOLD}${CYAN}=== $1 ===${NC}"
    fi
}

print_ok() {
    PASSED=$((PASSED + 1))
    if [[ "$QUIET" == false ]]; then
        echo -e "  ${GREEN}[OK]${NC}    $1"
    fi
}

print_fail() {
    FAILED=$((FAILED + 1))
    if [[ "$QUIET" == false ]]; then
        echo -e "  ${RED}[FAIL]${NC}  $1"
    fi
}

print_skip() {
    SKIPPED=$((SKIPPED + 1))
    if [[ "$QUIET" == false ]]; then
        echo -e "  ${YELLOW}[SKIP]${NC}  $1"
    fi
}

# ---------------------------------------------------------------------------
# Check functions
# ---------------------------------------------------------------------------

check_container_running() {
    local container="$1"
    docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q "true"
}

check_http() {
    local url="$1"
    local timeout="${2:-5}"
    curl -sf --max-time "$timeout" "$url" > /dev/null 2>&1
}

check_http_status() {
    local url="$1"
    local timeout="${2:-5}"
    local status
    status=$(curl -so /dev/null -w "%{http_code}" --max-time "$timeout" "$url" 2>/dev/null)
    [[ "$status" -ge 200 && "$status" -lt 400 ]]
}

# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------

check_postgres() {
    print_header "PostgreSQL"

    # Check if container is running
    if ! check_container_running "$POSTGRES_CONTAINER"; then
        print_fail "PostgreSQL container is not running ($POSTGRES_CONTAINER)"
        return
    fi

    # Check pg_isready
    if docker exec "$POSTGRES_CONTAINER" pg_isready -U "$POSTGRES_USER" -q 2>/dev/null; then
        print_ok "PostgreSQL is accepting connections"
    else
        print_fail "PostgreSQL is not accepting connections"
        return
    fi

    # Check each database exists
    for db in "${DATABASES[@]}"; do
        if docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$db" -c "SELECT 1" > /dev/null 2>&1; then
            print_ok "Database '$db' exists and is accessible"
        else
            print_fail "Database '$db' does not exist or is not accessible"
        fi
    done
}

# ---------------------------------------------------------------------------
# Redis
# ---------------------------------------------------------------------------

check_redis() {
    print_header "Redis"

    if ! check_container_running "$REDIS_CONTAINER"; then
        print_fail "Redis container is not running ($REDIS_CONTAINER)"
        return
    fi

    if docker exec "$REDIS_CONTAINER" redis-cli ping 2>/dev/null | grep -q "PONG"; then
        print_ok "Redis is responding to PING"
    else
        print_fail "Redis is not responding"
    fi

    # Check memory usage
    local used_memory
    used_memory=$(docker exec "$REDIS_CONTAINER" redis-cli info memory 2>/dev/null | grep "used_memory_human" | cut -d: -f2 | tr -d '[:space:]')
    if [[ -n "$used_memory" ]]; then
        print_ok "Redis memory usage: $used_memory"
    fi
}

# ---------------------------------------------------------------------------
# FalkorDB
# ---------------------------------------------------------------------------

check_falkordb() {
    print_header "FalkorDB"

    if ! check_container_running "$FALKORDB_CONTAINER"; then
        print_fail "FalkorDB container is not running ($FALKORDB_CONTAINER)"
        return
    fi

    if docker exec "$FALKORDB_CONTAINER" redis-cli -p "$FALKORDB_PORT" ping 2>/dev/null | grep -q "PONG"; then
        print_ok "FalkorDB is responding to PING on port $FALKORDB_PORT"
    else
        print_fail "FalkorDB is not responding on port $FALKORDB_PORT"
    fi

    # Check if graph module is loaded
    if docker exec "$FALKORDB_CONTAINER" redis-cli -p "$FALKORDB_PORT" MODULE LIST 2>/dev/null | grep -qi "graph"; then
        print_ok "FalkorDB graph module is loaded"
    else
        print_fail "FalkorDB graph module is not loaded"
    fi
}

# ---------------------------------------------------------------------------
# MinIO
# ---------------------------------------------------------------------------

check_minio() {
    print_header "MinIO"

    if ! check_container_running "$MINIO_CONTAINER"; then
        print_fail "MinIO container is not running ($MINIO_CONTAINER)"
        return
    fi

    # Check health endpoint
    if check_http "http://localhost:9000/minio/health/live"; then
        print_ok "MinIO health endpoint is responding"
    else
        print_fail "MinIO health endpoint is not responding"
    fi

    # Check buckets exist
    for bucket in "${MINIO_BUCKETS[@]}"; do
        if docker exec "$MINIO_CONTAINER" mc ls "local/$bucket" > /dev/null 2>&1; then
            print_ok "MinIO bucket '$bucket' exists"
        else
            print_fail "MinIO bucket '$bucket' does not exist"
        fi
    done
}

# ---------------------------------------------------------------------------
# Nginx
# ---------------------------------------------------------------------------

check_nginx() {
    print_header "Nginx"

    if check_http "$NGINX_URL"; then
        print_ok "Nginx is responding at $NGINX_URL"
    elif check_http_status "$NGINX_URL"; then
        print_ok "Nginx is responding at $NGINX_URL (non-200 but valid)"
    else
        print_fail "Nginx is not responding at $NGINX_URL"
    fi
}

# ---------------------------------------------------------------------------
# Authentik
# ---------------------------------------------------------------------------

check_authentik() {
    print_header "Authentik"

    if check_http "${AUTHENTIK_URL}/-/health/ready/"; then
        print_ok "Authentik is healthy"
    elif check_http_status "${AUTHENTIK_URL}/-/health/ready/"; then
        print_ok "Authentik is responding (health endpoint returned non-200)"
    else
        print_fail "Authentik health endpoint is not responding"
    fi
}

# ---------------------------------------------------------------------------
# Supabase Kong
# ---------------------------------------------------------------------------

check_supabase() {
    print_header "Supabase (Kong Gateway)"

    if check_http_status "${SUPABASE_KONG_URL}/"; then
        print_ok "Supabase Kong is responding"
    else
        print_fail "Supabase Kong is not responding at $SUPABASE_KONG_URL"
    fi

    # Check PostgREST through Kong
    if check_http_status "${SUPABASE_KONG_URL}/rest/v1/"; then
        print_ok "Supabase PostgREST is responding through Kong"
    else
        print_fail "Supabase PostgREST is not responding"
    fi
}

# ---------------------------------------------------------------------------
# LiteLLM
# ---------------------------------------------------------------------------

check_litellm() {
    print_header "LiteLLM"

    if check_http "${LITELLM_URL}/health"; then
        print_ok "LiteLLM health endpoint is healthy"
    elif check_http_status "${LITELLM_URL}/health"; then
        print_ok "LiteLLM is responding (check health details)"
    else
        print_fail "LiteLLM health endpoint is not responding"
    fi
}

# ---------------------------------------------------------------------------
# Dify
# ---------------------------------------------------------------------------

check_dify() {
    print_header "Dify"

    # Check API health
    if check_http "${DIFY_URL}/health"; then
        print_ok "Dify API is healthy"
    elif check_http_status "${DIFY_URL}/health"; then
        print_ok "Dify API is responding (check health details)"
    else
        print_fail "Dify API health endpoint is not responding"
    fi
}

# ---------------------------------------------------------------------------
# Hatchet
# ---------------------------------------------------------------------------

check_hatchet() {
    print_header "Hatchet"

    if check_http "${HATCHET_URL}/api/ready"; then
        print_ok "Hatchet engine is ready"
    elif check_http_status "${HATCHET_URL}/api/ready"; then
        print_ok "Hatchet engine is responding"
    elif check_http "${HATCHET_URL}/api/v1/meta"; then
        print_ok "Hatchet API is responding"
    else
        print_fail "Hatchet is not responding"
    fi
}

# ---------------------------------------------------------------------------
# Langfuse
# ---------------------------------------------------------------------------

check_langfuse() {
    print_header "Langfuse"

    if check_http "${LANGFUSE_URL}/api/public/health"; then
        print_ok "Langfuse is healthy"
    elif check_http_status "${LANGFUSE_URL}/api/public/health"; then
        print_ok "Langfuse is responding"
    else
        print_fail "Langfuse health endpoint is not responding"
    fi
}

# ---------------------------------------------------------------------------
# n8n
# ---------------------------------------------------------------------------

check_n8n() {
    print_header "n8n"

    if check_http "${N8N_URL}/healthz"; then
        print_ok "n8n is healthy"
    elif check_http_status "${N8N_URL}/healthz"; then
        print_ok "n8n is responding"
    else
        print_fail "n8n health endpoint is not responding"
    fi
}

# ---------------------------------------------------------------------------
# Outline (optional service)
# ---------------------------------------------------------------------------

check_outline() {
    print_header "Outline"

    if check_http "${OUTLINE_URL}/api/info" 3; then
        print_ok "Outline is healthy"
    elif check_http_status "${OUTLINE_URL}/api/info" 3; then
        print_ok "Outline is responding"
    elif ! check_http_status "${OUTLINE_URL}" 3; then
        print_skip "Outline is not running (optional service)"
    else
        print_fail "Outline is not responding correctly"
    fi
}

# ---------------------------------------------------------------------------
# GitLab (optional service)
# ---------------------------------------------------------------------------

check_gitlab() {
    print_header "GitLab"

    if check_http "${GITLAB_URL}/-/readiness" 10; then
        print_ok "GitLab readiness check passed"
    elif check_http "${GITLAB_URL}/-/health" 10; then
        print_ok "GitLab health check passed"
    elif check_http_status "${GITLAB_URL}/-/health" 10; then
        print_ok "GitLab is responding"
    elif ! check_http_status "${GITLAB_URL}" 10; then
        print_skip "GitLab is not running (optional service)"
    else
        print_fail "GitLab is not responding correctly"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    if [[ "$QUIET" == false ]]; then
        echo -e "${BOLD}EchoThink Infrastructure Health Check${NC}"
        echo "$(date '+%Y-%m-%d %H:%M:%S')"
    fi

    check_postgres
    check_redis
    check_falkordb
    check_minio
    check_nginx
    check_authentik
    check_supabase
    check_litellm
    check_dify
    check_hatchet
    check_langfuse
    check_n8n
    check_outline
    check_gitlab

    # Summary
    echo ""
    echo -e "${BOLD}--- Summary ---${NC}"
    echo -e "  ${GREEN}Passed:${NC}  $PASSED"
    echo -e "  ${RED}Failed:${NC}  $FAILED"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIPPED"
    echo ""

    if [[ $FAILED -gt 0 ]]; then
        echo -e "${RED}${BOLD}Health check FAILED -- $FAILED check(s) did not pass.${NC}"
        exit 1
    else
        echo -e "${GREEN}${BOLD}All checks passed.${NC}"
        exit 0
    fi
}

main
