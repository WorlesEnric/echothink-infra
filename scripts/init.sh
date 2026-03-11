#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Generate a random hex string
gen_secret() {
    openssl rand -hex "$1"
}

# Generate a random alphanumeric password
gen_password() {
    openssl rand -base64 "$1" | tr -d '/+=' | head -c "$1"
}

# Generate a JWT token
gen_jwt() {
    local role="$1"
    local secret="$2"

    local header
    header=$(echo -n '{"alg":"HS256","typ":"JWT"}' | openssl base64 -e | tr -d '=' | tr '/+' '_-' | tr -d '\n')

    local now
    now=$(date +%s)
    local exp=$((now + 157680000))  # 5 years from now

    local payload
    payload=$(echo -n "{\"role\":\"${role}\",\"iss\":\"supabase\",\"iat\":${now},\"exp\":${exp}}" | openssl base64 -e | tr -d '=' | tr '/+' '_-' | tr -d '\n')

    local signature
    signature=$(echo -n "${header}.${payload}" | openssl dgst -sha256 -hmac "$secret" -binary | openssl base64 -e | tr -d '=' | tr '/+' '_-' | tr -d '\n')

    echo "${header}.${payload}.${signature}"
}

# Replace a placeholder value in .env
set_env() {
    local key="$1"
    local value="$2"
    local file="$PROJECT_DIR/.env"

    if grep -q "^${key}=" "$file" 2>/dev/null; then
        # Only replace if it still has a CHANGE_ME placeholder
        if grep -q "^${key}=CHANGE_ME" "$file" 2>/dev/null; then
            sed -i.bak "s|^${key}=CHANGE_ME.*|${key}=${value}|" "$file"
            return 0
        fi
        return 1
    fi

    printf '\n%s=%s\n' "$key" "$value" >> "$file"
    return 0
}

echo ""
echo "=============================================="
echo "   EchoThink Infrastructure Initialization"
echo "=============================================="
echo ""

# Step 1: Create .env from .env.example if it doesn't exist
if [ ! -f "$PROJECT_DIR/.env" ]; then
    if [ ! -f "$PROJECT_DIR/.env.example" ]; then
        error ".env.example not found. Cannot initialize."
    fi
    cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
    ok "Created .env from .env.example"
else
    warn ".env already exists. Only CHANGE_ME values will be updated."
fi

# Step 2: Generate passwords and secrets
info "Generating passwords and secrets..."

GENERATED=0

# PostgreSQL passwords
if set_env "POSTGRES_PASSWORD" "$(gen_password 32)"; then ((GENERATED++)); fi
if set_env "SUPABASE_DB_PASSWORD" "$(gen_password 24)"; then ((GENERATED++)); fi
if set_env "SUPABASE_DASHBOARD_PASSWORD" "$(gen_password 24)"; then ((GENERATED++)); fi
if set_env "REDIS_PASSWORD" "$(gen_password 24)"; then ((GENERATED++)); fi
if set_env "SUPABASE_LOGFLARE_PUBLIC_ACCESS_TOKEN" "$(gen_password 32)"; then ((GENERATED++)); fi
if set_env "SUPABASE_LOGFLARE_PRIVATE_ACCESS_TOKEN" "$(gen_password 32)"; then ((GENERATED++)); fi
if set_env "HATCHET_DB_PASSWORD" "$(gen_password 24)"; then ((GENERATED++)); fi
if set_env "LANGFUSE_DB_PASSWORD" "$(gen_password 24)"; then ((GENERATED++)); fi
if set_env "N8N_DB_PASSWORD" "$(gen_password 24)"; then ((GENERATED++)); fi
if set_env "AUTHENTIK_DB_PASSWORD" "$(gen_password 24)"; then ((GENERATED++)); fi
if set_env "DIFY_DB_PASSWORD" "$(gen_password 24)"; then ((GENERATED++)); fi
if set_env "OUTLINE_DB_PASSWORD" "$(gen_password 24)"; then ((GENERATED++)); fi
if set_env "LITELLM_DB_PASSWORD" "$(gen_password 24)"; then ((GENERATED++)); fi
if set_env "GITLAB_DB_PASSWORD" "$(gen_password 24)"; then ((GENERATED++)); fi

# MinIO
if set_env "MINIO_ROOT_PASSWORD" "$(gen_password 32)"; then ((GENERATED++)); fi

# Supabase JWT
JWT_SECRET="$(gen_secret 32)"
if set_env "SUPABASE_JWT_SECRET" "$JWT_SECRET"; then
    ((GENERATED++))
    # Generate JWT tokens using the new secret
    ANON_KEY=$(gen_jwt "anon" "$JWT_SECRET")
    SERVICE_ROLE_KEY=$(gen_jwt "service_role" "$JWT_SECRET")
    set_env "SUPABASE_ANON_KEY" "$ANON_KEY" && ((GENERATED++))
    set_env "SUPABASE_SERVICE_ROLE_KEY" "$SERVICE_ROLE_KEY" && ((GENERATED++))
    ok "Generated Supabase JWT tokens"
else
    # If JWT secret already set, read it for potential token regeneration
    JWT_SECRET=$(grep "^SUPABASE_JWT_SECRET=" "$PROJECT_DIR/.env" | cut -d= -f2)
    if set_env "SUPABASE_ANON_KEY" "$(gen_jwt "anon" "$JWT_SECRET")"; then ((GENERATED++)); fi
    if set_env "SUPABASE_SERVICE_ROLE_KEY" "$(gen_jwt "service_role" "$JWT_SECRET")"; then ((GENERATED++)); fi
fi

if set_env "SUPABASE_REALTIME_SECRET_KEY_BASE" "$(gen_secret 32)"; then ((GENERATED++)); fi

# Authentik
if set_env "AUTHENTIK_SECRET_KEY" "$(gen_secret 32)"; then ((GENERATED++)); fi
if set_env "AUTHENTIK_BOOTSTRAP_PASSWORD" "$(gen_password 24)"; then ((GENERATED++)); fi
if set_env "AUTHENTIK_BOOTSTRAP_TOKEN" "$(gen_secret 32)"; then ((GENERATED++)); fi

# LiteLLM
if set_env "LITELLM_MASTER_KEY" "sk-$(gen_secret 24)"; then ((GENERATED++)); fi

# Langfuse
if set_env "LANGFUSE_SECRET_KEY" "$(gen_secret 32)"; then ((GENERATED++)); fi
if set_env "LANGFUSE_NEXT_AUTH_SECRET" "$(gen_secret 32)"; then ((GENERATED++)); fi
if set_env "LANGFUSE_SALT" "$(gen_secret 16)"; then ((GENERATED++)); fi

# n8n
if set_env "N8N_ENCRYPTION_KEY" "$(gen_secret 24)"; then ((GENERATED++)); fi

# Dify
if set_env "DIFY_SECRET_KEY" "$(gen_secret 32)"; then ((GENERATED++)); fi

# Outline
if set_env "OUTLINE_SECRET_KEY" "$(gen_secret 32)"; then ((GENERATED++)); fi
if set_env "OUTLINE_UTILS_SECRET" "$(gen_secret 32)"; then ((GENERATED++)); fi

# GitLab
if set_env "GITLAB_ROOT_PASSWORD" "$(gen_password 24)"; then ((GENERATED++)); fi
if set_env "GITLAB_SHARED_RUNNERS_TOKEN" "$(gen_secret 20)"; then ((GENERATED++)); fi

# Hatchet
if set_env "HATCHET_CLIENT_TOKEN" "$(gen_secret 32)"; then ((GENERATED++)); fi
if set_env "HATCHET_JWT_SECRET" "$(gen_secret 32)"; then ((GENERATED++)); fi
if set_env "HATCHET_AUTH_COOKIE_SECRETS" "$(gen_secret 32) $(gen_secret 32)"; then ((GENERATED++)); fi
if set_env "HATCHET_ENCRYPTION_MASTER_KEYSET" "$(gen_secret 64)"; then ((GENERATED++)); fi
if set_env "HATCHET_ENCRYPTION_JWT_PRIVATE_KEYSET" "$(gen_secret 64)"; then ((GENERATED++)); fi
if set_env "HATCHET_ENCRYPTION_JWT_PUBLIC_KEYSET" "$(gen_secret 64)"; then ((GENERATED++)); fi

ok "Generated $GENERATED secrets/passwords"

# Clean up sed backup files
rm -f "$PROJECT_DIR/.env.bak"

# Step 3: Update PostgreSQL init script placeholders with generated passwords
info "Updating database role passwords in init scripts..."

ROLES_FILE="$PROJECT_DIR/services/postgres/init/02-roles.sql"
if [ -f "$ROLES_FILE" ]; then
    SUPABASE_DB_PW=$(grep "^SUPABASE_DB_PASSWORD=" "$PROJECT_DIR/.env" | cut -d= -f2)
    HATCHET_DB_PW=$(grep "^HATCHET_DB_PASSWORD=" "$PROJECT_DIR/.env" | cut -d= -f2)
    LANGFUSE_DB_PW=$(grep "^LANGFUSE_DB_PASSWORD=" "$PROJECT_DIR/.env" | cut -d= -f2)
    N8N_DB_PW=$(grep "^N8N_DB_PASSWORD=" "$PROJECT_DIR/.env" | cut -d= -f2)
    AUTHENTIK_DB_PW=$(grep "^AUTHENTIK_DB_PASSWORD=" "$PROJECT_DIR/.env" | cut -d= -f2)
    DIFY_DB_PW=$(grep "^DIFY_DB_PASSWORD=" "$PROJECT_DIR/.env" | cut -d= -f2)
    OUTLINE_DB_PW=$(grep "^OUTLINE_DB_PASSWORD=" "$PROJECT_DIR/.env" | cut -d= -f2)
    LITELLM_DB_PW=$(grep "^LITELLM_DB_PASSWORD=" "$PROJECT_DIR/.env" | cut -d= -f2)
    GITLAB_DB_PW=$(grep "^GITLAB_DB_PASSWORD=" "$PROJECT_DIR/.env" | cut -d= -f2)

    sed -i.bak \
        -e "s|SUPABASE_DB_PASSWORD_PLACEHOLDER|${SUPABASE_DB_PW}|g" \
        -e "s|HATCHET_DB_PASSWORD_PLACEHOLDER|${HATCHET_DB_PW}|g" \
        -e "s|LANGFUSE_DB_PASSWORD_PLACEHOLDER|${LANGFUSE_DB_PW}|g" \
        -e "s|N8N_DB_PASSWORD_PLACEHOLDER|${N8N_DB_PW}|g" \
        -e "s|AUTHENTIK_DB_PASSWORD_PLACEHOLDER|${AUTHENTIK_DB_PW}|g" \
        -e "s|DIFY_DB_PASSWORD_PLACEHOLDER|${DIFY_DB_PW}|g" \
        -e "s|OUTLINE_DB_PASSWORD_PLACEHOLDER|${OUTLINE_DB_PW}|g" \
        -e "s|LITELLM_DB_PASSWORD_PLACEHOLDER|${LITELLM_DB_PW}|g" \
        -e "s|GITLAB_DB_PASSWORD_PLACEHOLDER|${GITLAB_DB_PW}|g" \
        "$ROLES_FILE"
    rm -f "${ROLES_FILE}.bak"
    ok "Updated database role passwords"
fi

# Step 4: Generate self-signed SSL certificates if not present
SSL_DIR="$PROJECT_DIR/services/nginx/ssl"
if [ ! -f "$SSL_DIR/server.crt" ] || [ ! -f "$SSL_DIR/server.key" ]; then
    info "Generating self-signed SSL certificates..."
    DOMAIN=$(grep "^DOMAIN=" "$PROJECT_DIR/.env" | cut -d= -f2)
    DOMAIN="${DOMAIN:-localhost}"

    openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout "$SSL_DIR/server.key" \
        -out "$SSL_DIR/server.crt" \
        -subj "/C=US/ST=Local/L=Local/O=EchoThink/CN=*.${DOMAIN}" \
        -addext "subjectAltName=DNS:*.${DOMAIN},DNS:${DOMAIN},DNS:localhost" \
        2>/dev/null

    ok "Generated self-signed SSL certificate for *.${DOMAIN}"
else
    warn "SSL certificates already exist, skipping generation"
fi

# Step 5: Print summary
echo ""
echo "=============================================="
echo "   Initialization Complete"
echo "=============================================="
echo ""
info "Configuration file: $PROJECT_DIR/.env"
info "SSL certificates:   $SSL_DIR/"
echo ""
info "Next steps:"
echo "  1. Review and customize .env as needed"
echo "  2. Set your LLM API keys (OPENAI_API_KEY, ANTHROPIC_API_KEY)"
echo "  3. Configure SMTP settings for email delivery"
echo "  4. Run 'make build' to build custom images"
echo "  5. Run 'make up' to start the infrastructure"
echo ""
warn "For production, replace the self-signed SSL certs with real ones."
echo ""
