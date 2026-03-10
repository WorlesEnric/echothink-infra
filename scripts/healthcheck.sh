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
NEO4J_CONTAINER="${ECHOTHINK_NEO4J_CONTAINER:-echothink-neo4j}"
MINIO_CONTAINER="${ECHOTHINK_MINIO_CONTAINER:-echothink-minio}"
AUTHENTIK_CONTAINER="${ECHOTHINK_AUTHENTIK_CONTAINER:-authentik-server}"
LANGFUSE_CLICKHOUSE_CONTAINER="${ECHOTHINK_CLICKHOUSE_CONTAINER:-langfuse-clickhouse}"
LANGFUSE_CONTAINER="${ECHOTHINK_LANGFUSE_CONTAINER:-langfuse}"
N8N_CONTAINER="${ECHOTHINK_N8N_CONTAINER:-n8n}"
OUTLINE_CONTAINER="${ECHOTHINK_OUTLINE_CONTAINER:-outline}"
GITLAB_CONTAINER="${ECHOTHINK_GITLAB_CONTAINER:-gitlab}"

POSTGRES_USER="${POSTGRES_USER:-postgres}"

# Service URLs (accessible from the host)
NGINX_URL="${NGINX_URL:-http://localhost:80}"
AUTHENTIK_URL="${AUTHENTIK_URL:-http://localhost:9000}"
SUPABASE_KONG_URL="${SUPABASE_KONG_URL:-http://localhost:8000}"
LITELLM_URL="${LITELLM_URL:-http://localhost:4000}"
DIFY_URL="${DIFY_URL:-http://localhost:5001}"
HATCHET_URL="${HATCHET_URL:-http://localhost:8080}"
LANGFUSE_URL="${LANGFUSE_URL:-http://localhost:3100}"
N8N_URL="${N8N_URL:-http://localhost:5678}"
OUTLINE_URL="${OUTLINE_URL:-http://localhost:3200}"
GITLAB_URL="${GITLAB_URL:-http://localhost:8929}"

# Databases that should exist in PostgreSQL
DATABASES=(postgres authentik supabase dify hatchet langfuse litellm n8n outline gitlab)

# MinIO buckets that should exist (representative subset)
MINIO_BUCKETS=(supabase-storage dify-storage outline-data artifacts backups langfuse-events langfuse-media)

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

    if ! check_container_running "$POSTGRES_CONTAINER"; then
        print_fail "PostgreSQL container is not running ($POSTGRES_CONTAINER)"
        return
    fi

    if docker exec "$POSTGRES_CONTAINER" pg_isready -U "$POSTGRES_USER" -q 2>/dev/null; then
        print_ok "PostgreSQL is accepting connections"
    else
        print_fail "PostgreSQL is not accepting connections"
        return
    fi

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

    local used_memory
    used_memory=$(docker exec "$REDIS_CONTAINER" redis-cli info memory 2>/dev/null | grep "used_memory_human" | cut -d: -f2 | tr -d '[:space:]')
    if [[ -n "$used_memory" ]]; then
        print_ok "Redis memory usage: $used_memory"
    fi
}

# ---------------------------------------------------------------------------
# Neo4j (Graph Database for Graphiti)
# ---------------------------------------------------------------------------

check_neo4j() {
    print_header "Neo4j"

    if ! check_container_running "$NEO4J_CONTAINER"; then
        print_skip "Neo4j container is not running ($NEO4J_CONTAINER)"
        return
    fi

    # Check Neo4j HTTP endpoint from inside the container
    if docker exec "$NEO4J_CONTAINER" wget --spider -q http://localhost:7474 2>/dev/null; then
        print_ok "Neo4j is responding on port 7474"
    else
        print_fail "Neo4j is not responding on port 7474"
    fi

    # Check Bolt protocol port
    if docker exec "$NEO4J_CONTAINER" sh -c 'echo | timeout 3 nc -z localhost 7687' 2>/dev/null; then
        print_ok "Neo4j Bolt protocol is listening on port 7687"
    else
        print_fail "Neo4j Bolt protocol is not available on port 7687"
    fi
}

# ---------------------------------------------------------------------------
# Graphiti Server
# ---------------------------------------------------------------------------

check_graphiti() {
    print_header "Graphiti"

    # Graphiti doesn't expose a host port by default (only internal 8000)
    # Check via container if possible
    local graphiti_containers
    graphiti_containers=$(docker ps --filter "name=graphiti" --format '{{.Names}}' 2>/dev/null | head -1)

    if [[ -z "$graphiti_containers" ]]; then
        print_skip "Graphiti container is not running"
        return
    fi

    if docker exec "$graphiti_containers" curl -sf http://localhost:8000/healthcheck > /dev/null 2>&1; then
        print_ok "Graphiti server is healthy"
    else
        print_fail "Graphiti server healthcheck failed"
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

    # Check MinIO readiness via mc inside the container
    if docker exec "$MINIO_CONTAINER" mc ready local 2>/dev/null; then
        print_ok "MinIO is ready"
    else
        print_fail "MinIO is not ready"
    fi

    # Check buckets exist (mc in the minio container uses 'local' alias by default)
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

    if ! check_container_running "$AUTHENTIK_CONTAINER"; then
        print_fail "Authentik container is not running ($AUTHENTIK_CONTAINER)"
        return
    fi

    # Use the internal ak healthcheck command for reliability
    if docker exec "$AUTHENTIK_CONTAINER" ak healthcheck 2>/dev/null; then
        print_ok "Authentik server is healthy"
    else
        # Fall back to HTTP check
        if check_http_status "${AUTHENTIK_URL}/-/health/ready/"; then
            print_ok "Authentik is responding (HTTP ready endpoint)"
        else
            print_fail "Authentik health check failed"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Supabase
# ---------------------------------------------------------------------------

check_supabase() {
    print_header "Supabase"

    # Kong API Gateway
    if check_container_running "supabase-kong"; then
        if docker exec supabase-kong kong health 2>/dev/null; then
            print_ok "Supabase Kong gateway is healthy"
        elif check_http_status "${SUPABASE_KONG_URL}/"; then
            print_ok "Supabase Kong is responding"
        else
            print_fail "Supabase Kong is not responding"
        fi
    else
        print_fail "Supabase Kong container is not running"
    fi

    # Auth (GoTrue)
    if check_container_running "supabase-auth"; then
        if docker exec supabase-auth wget --spider -q http://localhost:9999/health 2>/dev/null; then
            print_ok "Supabase Auth (GoTrue) is healthy"
        else
            print_fail "Supabase Auth is not responding"
        fi
    else
        print_fail "Supabase Auth container is not running"
    fi

    # PostgREST (via Kong)
    if check_http_status "${SUPABASE_KONG_URL}/rest/v1/"; then
        print_ok "Supabase PostgREST is responding through Kong"
    else
        print_fail "Supabase PostgREST is not responding"
    fi

    # Storage
    if check_container_running "supabase-storage"; then
        if docker exec supabase-storage wget --spider -q http://127.0.0.1:5000/status 2>/dev/null; then
            print_ok "Supabase Storage is healthy"
        else
            print_fail "Supabase Storage is not responding"
        fi
    else
        print_fail "Supabase Storage container is not running"
    fi

    # Studio
    if check_container_running "supabase-studio"; then
        print_ok "Supabase Studio is running"
    else
        print_skip "Supabase Studio is not running"
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

    # Dify API
    if check_http "${DIFY_URL}/health"; then
        print_ok "Dify API is healthy"
    elif check_http_status "${DIFY_URL}/health"; then
        print_ok "Dify API is responding (check health details)"
    else
        print_fail "Dify API health endpoint is not responding"
    fi

    # Dify Web
    if check_container_running "echothink-dify-web"; then
        print_ok "Dify Web container is running"
    else
        print_fail "Dify Web container is not running"
    fi
}

# ---------------------------------------------------------------------------
# Hatchet
# ---------------------------------------------------------------------------

check_hatchet() {
    print_header "Hatchet"

    # Hatchet Engine
    local engine_containers
    engine_containers=$(docker ps --filter "name=hatchet-engine" --format '{{.Names}}' 2>/dev/null | head -1)

    if [[ -n "$engine_containers" ]]; then
        if docker exec "$engine_containers" wget --spider -q http://localhost:8733/ready 2>/dev/null; then
            print_ok "Hatchet engine is ready"
        else
            print_fail "Hatchet engine is not ready"
        fi
    else
        print_fail "Hatchet engine container is not running"
    fi

    # Hatchet API
    if check_http "${HATCHET_URL}/api/ready"; then
        print_ok "Hatchet API is ready"
    elif check_http_status "${HATCHET_URL}/api/ready"; then
        print_ok "Hatchet API is responding"
    else
        print_fail "Hatchet API is not responding at $HATCHET_URL"
    fi
}

# ---------------------------------------------------------------------------
# ClickHouse (Langfuse dependency)
# ---------------------------------------------------------------------------

check_clickhouse() {
    print_header "ClickHouse"

    if ! check_container_running "$LANGFUSE_CLICKHOUSE_CONTAINER"; then
        print_fail "ClickHouse container is not running ($LANGFUSE_CLICKHOUSE_CONTAINER)"
        return
    fi

    if docker exec "$LANGFUSE_CLICKHOUSE_CONTAINER" wget --spider -q http://localhost:8123/ping 2>/dev/null; then
        print_ok "ClickHouse is responding to ping"
    else
        print_fail "ClickHouse is not responding"
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

    if check_http "${OUTLINE_URL}/_health" 3; then
        print_ok "Outline is healthy"
    elif check_http_status "${OUTLINE_URL}/_health" 3; then
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

    if ! check_container_running "$GITLAB_CONTAINER"; then
        print_skip "GitLab is not running (optional service)"
        return
    fi

    # Use gitlab-ctl status (matches compose healthcheck)
    if docker exec "$GITLAB_CONTAINER" gitlab-ctl status > /dev/null 2>&1; then
        print_ok "GitLab services are running"
    else
        print_fail "GitLab services are not all running"
    fi

    # Also check HTTP readiness
    if check_http "${GITLAB_URL}/-/readiness" 10; then
        print_ok "GitLab readiness check passed"
    elif check_http_status "${GITLAB_URL}/-/health" 10; then
        print_ok "GitLab HTTP health check passed"
    else
        print_fail "GitLab HTTP endpoints are not responding"
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

    # Core infrastructure
    check_postgres
    check_redis
    check_minio
    check_nginx

    # Graph database
    check_neo4j
    check_graphiti

    # Identity & access
    check_authentik

    # Backend-as-a-service
    check_supabase

    # AI & LLM services
    check_litellm
    check_dify

    # Task orchestration
    check_hatchet

    # Observability
    check_clickhouse
    check_langfuse

    # Automation
    check_n8n

    # Optional services
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
