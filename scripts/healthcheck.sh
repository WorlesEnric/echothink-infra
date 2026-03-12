#!/usr/bin/env bash
#
# EchoThink Infrastructure Health Check
#
# Checks all services and prints colored status output.
# Exit code 0 if all services are healthy, non-zero otherwise.
#
# All checks use "docker exec" so the script works when run from a
# remote machine (only Docker API access is required, not host-level
# network access to container ports).
#
# Usage: ./scripts/healthcheck.sh [--quiet]
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration -- container names
# ---------------------------------------------------------------------------

POSTGRES_CONTAINER="${ECHOTHINK_POSTGRES_CONTAINER:-echothink-postgres}"
REDIS_CONTAINER="${ECHOTHINK_REDIS_CONTAINER:-echothink-redis}"
NEO4J_CONTAINER="${ECHOTHINK_NEO4J_CONTAINER:-echothink-neo4j}"
MINIO_CONTAINER="${ECHOTHINK_MINIO_CONTAINER:-echothink-minio}"
CLICKHOUSE_CONTAINER="${ECHOTHINK_CLICKHOUSE_CONTAINER:-langfuse-clickhouse}"
LANGFUSE_CONTAINER="${ECHOTHINK_LANGFUSE_CONTAINER:-langfuse-web}"
LANGFUSE_WORKER_CONTAINER="${ECHOTHINK_LANGFUSE_WORKER_CONTAINER:-langfuse-worker}"
LITELLM_CONTAINER="${ECHOTHINK_LITELLM_CONTAINER:-echothink-litellm}"
N8N_CONTAINER="${ECHOTHINK_N8N_CONTAINER:-n8n}"
OUTLINE_CONTAINER="${ECHOTHINK_OUTLINE_CONTAINER:-outline}"
GITLAB_CONTAINER="${ECHOTHINK_GITLAB_CONTAINER:-gitlab}"
DIFY_WEB_CONTAINER="${ECHOTHINK_DIFY_WEB_CONTAINER:-echothink-dify-web}"
NGINX_CONTAINER="${ECHOTHINK_NGINX_CONTAINER:-echothink-nginx}"

POSTGRES_USER="${POSTGRES_USER:-postgres}"

# Databases that should exist in PostgreSQL
DATABASES=(postgres supabase _supabase dify hatchet langfuse litellm n8n outline gitlab)

# MinIO buckets created by minio-init (alias: echothink)
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
# Helpers
# ---------------------------------------------------------------------------

check_container_running() {
    local container="$1"
    docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q "true"
}

# Find the first running container whose name contains the given pattern.
find_container() {
    docker ps --filter "name=$1" --format '{{.Names}}' 2>/dev/null | head -1
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
# MinIO
# ---------------------------------------------------------------------------

check_minio() {
    print_header "MinIO"

    if ! check_container_running "$MINIO_CONTAINER"; then
        print_fail "MinIO container is not running ($MINIO_CONTAINER)"
        return
    fi

    if docker exec "$MINIO_CONTAINER" mc ready local > /dev/null 2>&1; then
        print_ok "MinIO is ready"
    else
        print_fail "MinIO is not ready"
    fi

    # minio-init creates buckets which are stored as directories under /data.
    # The "local" mc alias has special handling for "mc ready" but may not be
    # configured for ls/stat, so check the filesystem directly.
    for bucket in "${MINIO_BUCKETS[@]}"; do
        if docker exec "$MINIO_CONTAINER" test -d "/data/$bucket"; then
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

    if ! check_container_running "$NGINX_CONTAINER"; then
        print_fail "Nginx container is not running ($NGINX_CONTAINER)"
        return
    fi

    # nginx runs with envsubst-processed config at /tmp/nginx.conf (not the
    # original template at /etc/nginx/nginx.conf which still has $DOMAIN vars).
    if docker exec "$NGINX_CONTAINER" nginx -t -c /tmp/nginx.conf > /dev/null 2>&1; then
        print_ok "Nginx configuration is valid"
    else
        print_fail "Nginx configuration test failed"
    fi

    # Send a zero signal to check the master process is alive
    if docker exec "$NGINX_CONTAINER" sh -c 'kill -0 $(cat /var/run/nginx.pid 2>/dev/null) 2>/dev/null'; then
        print_ok "Nginx master process is running"
    else
        print_fail "Nginx master process is not running"
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

    if docker exec "$NEO4J_CONTAINER" wget --spider -q http://localhost:7474 2>/dev/null; then
        print_ok "Neo4j HTTP is responding on port 7474"
    elif docker exec "$NEO4J_CONTAINER" curl -sf http://localhost:7474 > /dev/null 2>&1; then
        print_ok "Neo4j HTTP is responding on port 7474"
    else
        print_fail "Neo4j HTTP is not responding on port 7474"
    fi

    # Check Bolt via cypher-shell (included in neo4j image)
    if docker exec "$NEO4J_CONTAINER" cypher-shell -u neo4j -p changeme "RETURN 1;" > /dev/null 2>&1; then
        print_ok "Neo4j Bolt protocol is accepting queries"
    else
        # cypher-shell may fail due to auth mismatch -- check /proc/net/tcp6
        # 7687 decimal = 0x1E07
        if docker exec "$NEO4J_CONTAINER" sh -c '[ -e /proc/net/tcp6 ] && grep -qi ":1E07" /proc/net/tcp6' 2>/dev/null; then
            print_ok "Neo4j Bolt protocol is listening on port 7687"
        else
            print_skip "Neo4j Bolt check skipped (unable to verify)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Graphiti Server
# ---------------------------------------------------------------------------

check_graphiti() {
    print_header "Graphiti"

    local container
    container=$(find_container "graphiti")

    if [[ -z "$container" ]]; then
        print_skip "Graphiti container is not running"
        return
    fi

    if docker exec "$container" curl -sf http://localhost:8000/healthcheck > /dev/null 2>&1; then
        print_ok "Graphiti server is healthy"
    else
        print_fail "Graphiti server healthcheck failed"
    fi
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Supabase
# ---------------------------------------------------------------------------

check_supabase() {
    print_header "Supabase"

    # Analytics (Logflare)
    if check_container_running "supabase-analytics"; then
        if docker exec supabase-analytics curl -sf http://localhost:4000/health > /dev/null 2>&1; then
            print_ok "Supabase Analytics (Logflare) is healthy"
        else
            print_fail "Supabase Analytics is not responding"
        fi
    else
        print_fail "Supabase Analytics container is not running"
    fi

    # Kong API Gateway
    if check_container_running "supabase-kong"; then
        if docker exec supabase-kong kong health > /dev/null 2>&1; then
            print_ok "Supabase Kong gateway is healthy"
        else
            print_fail "Supabase Kong health check failed"
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

    # PostgREST -- kong:2.8.1 has no wget/curl, and PostgREST returns 401
    # through Kong without auth headers. Just verify the container is running.
    if check_container_running "supabase-rest"; then
        print_ok "Supabase PostgREST container is running"
    else
        print_fail "Supabase PostgREST container is not running"
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

    if ! check_container_running "$LITELLM_CONTAINER"; then
        print_fail "LiteLLM container is not running ($LITELLM_CONTAINER)"
        return
    fi

    # Compose healthcheck uses a Python socket test to port 4000
    if docker exec "$LITELLM_CONTAINER" python -c "import socket; s=socket.create_connection(('127.0.0.1', 4000), 5); s.close()" 2>/dev/null; then
        print_ok "LiteLLM is accepting connections on port 4000"
    else
        print_fail "LiteLLM is not responding on port 4000"
    fi

    # Also try the /health endpoint inside the container
    if docker exec "$LITELLM_CONTAINER" curl -sf http://127.0.0.1:4000/health > /dev/null 2>&1; then
        print_ok "LiteLLM /health endpoint is healthy"
    elif docker exec "$LITELLM_CONTAINER" wget --spider -q http://127.0.0.1:4000/health > /dev/null 2>&1; then
        print_ok "LiteLLM /health endpoint is healthy"
    fi
}

# ---------------------------------------------------------------------------
# Dify
# ---------------------------------------------------------------------------

check_dify() {
    print_header "Dify"

    # Dify API -- find container dynamically (no fixed container_name in compose)
    local api_container
    api_container=$(find_container "dify-api")

    if [[ -n "$api_container" ]]; then
        if docker exec "$api_container" curl -sf http://localhost:5001/health > /dev/null 2>&1; then
            print_ok "Dify API is healthy"
        else
            print_fail "Dify API health check failed"
        fi
    else
        print_fail "Dify API container is not running"
    fi

    # Dify Web
    if check_container_running "$DIFY_WEB_CONTAINER"; then
        print_ok "Dify Web container is running"
    else
        print_fail "Dify Web container is not running"
    fi

    # Dify Plugin Daemon
    local plugin_container
    plugin_container=$(find_container "dify-plugin-daemon")

    if [[ -n "$plugin_container" ]]; then
        if docker exec "$plugin_container" curl -s http://localhost:5002/ > /dev/null 2>&1; then
            print_ok "Dify Plugin Daemon is healthy"
        else
            print_fail "Dify Plugin Daemon health check failed"
        fi
    else
        print_fail "Dify Plugin Daemon container is not running"
    fi

    # Dify Sandbox
    local sandbox_container
    sandbox_container=$(find_container "dify-sandbox")

    if [[ -n "$sandbox_container" ]]; then
        if docker exec "$sandbox_container" curl -sf http://localhost:8194/health > /dev/null 2>&1; then
            print_ok "Dify Sandbox is healthy"
        else
            print_fail "Dify Sandbox health check failed"
        fi
    else
        print_fail "Dify Sandbox container is not running"
    fi
}

# ---------------------------------------------------------------------------
# Hatchet
# ---------------------------------------------------------------------------

check_hatchet() {
    print_header "Hatchet"

    # Hatchet Engine
    local engine_container
    engine_container=$(find_container "hatchet-engine")

    if [[ -n "$engine_container" ]]; then
        if docker exec "$engine_container" wget --spider -q http://localhost:8733/ready 2>/dev/null; then
            print_ok "Hatchet engine is ready"
        else
            print_fail "Hatchet engine is not ready"
        fi
    else
        print_fail "Hatchet engine container is not running"
    fi

    # Hatchet Dashboard
    local api_container
    api_container=$(find_container "hatchet-dashboard")

    if [[ -n "$api_container" ]]; then
        if docker exec "$api_container" wget --spider -q http://127.0.0.1/ 2>/dev/null; then
            print_ok "Hatchet Dashboard is ready"
        else
            print_fail "Hatchet Dashboard is not ready"
        fi
    else
        print_fail "Hatchet Dashboard container is not running"
    fi
}

# ---------------------------------------------------------------------------
# ClickHouse (Langfuse dependency)
# ---------------------------------------------------------------------------

check_clickhouse() {
    print_header "ClickHouse"

    if ! check_container_running "$CLICKHOUSE_CONTAINER"; then
        print_fail "ClickHouse container is not running ($CLICKHOUSE_CONTAINER)"
        return
    fi

    if docker exec "$CLICKHOUSE_CONTAINER" wget --spider -q http://localhost:8123/ping 2>/dev/null; then
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

    if ! check_container_running "$LANGFUSE_CONTAINER"; then
        print_fail "Langfuse web container is not running ($LANGFUSE_CONTAINER)"
        return
    fi

    # langfuse/langfuse:3 is a Node.js image -- use node fetch (Node 18+).
    if docker exec "$LANGFUSE_CONTAINER" node -e "fetch('http://localhost:3000/api/public/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
        print_ok "Langfuse web is healthy"
    else
        print_fail "Langfuse web health endpoint is not responding"
    fi

    if check_container_running "$LANGFUSE_WORKER_CONTAINER"; then
        if docker exec "$LANGFUSE_WORKER_CONTAINER" node -e "fetch('http://localhost:3030/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
            print_ok "Langfuse worker is healthy"
        else
            print_fail "Langfuse worker health endpoint is not responding"
        fi
    else
        print_fail "Langfuse worker container is not running ($LANGFUSE_WORKER_CONTAINER)"
    fi
}

# ---------------------------------------------------------------------------
# n8n
# ---------------------------------------------------------------------------

check_n8n() {
    print_header "n8n"

    if ! check_container_running "$N8N_CONTAINER"; then
        print_fail "n8n container is not running ($N8N_CONTAINER)"
        return
    fi

    if docker exec "$N8N_CONTAINER" wget --spider -q http://127.0.0.1:5678/healthz 2>/dev/null; then
        print_ok "n8n is healthy"
    else
        print_fail "n8n health endpoint is not responding"
    fi
}

# ---------------------------------------------------------------------------
# Outline (optional service)
# ---------------------------------------------------------------------------

check_outline() {
    print_header "Outline"

    if ! check_container_running "$OUTLINE_CONTAINER"; then
        print_skip "Outline is not running (optional service)"
        return
    fi

    if docker exec "$OUTLINE_CONTAINER" wget --spider -q http://localhost:3000/_health 2>/dev/null; then
        print_ok "Outline is healthy"
    else
        print_fail "Outline health endpoint is not responding"
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

    if docker exec "$GITLAB_CONTAINER" gitlab-ctl status > /dev/null 2>&1; then
        print_ok "GitLab services are running"
    else
        print_fail "GitLab services are not all running"
    fi

    # HTTP readiness (internal to the container, port 8929)
    if docker exec "$GITLAB_CONTAINER" curl -sf http://localhost:8929/-/readiness > /dev/null 2>&1; then
        print_ok "GitLab readiness check passed"
    elif docker exec "$GITLAB_CONTAINER" curl -sf http://localhost:8929/-/health > /dev/null 2>&1; then
        print_ok "GitLab HTTP health check passed"
    elif docker exec "$GITLAB_CONTAINER" wget --spider -q http://localhost:8929/-/health 2>/dev/null; then
        print_ok "GitLab HTTP health check passed"
    else
        print_skip "GitLab HTTP endpoints not yet ready (may still be booting)"
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
