-- Create service-specific roles with placeholder passwords
-- These placeholders are replaced by the init.sh script before first run

-- supabase_admin (owns supabase + _supabase databases, used by realtime, meta, analytics)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_admin') THEN
    CREATE ROLE supabase_admin WITH LOGIN PASSWORD 'Ua2o3hFDi9gS7ih8Nzkaicdt';
  END IF;
END $$;
GRANT ALL PRIVILEGES ON DATABASE supabase TO supabase_admin;
ALTER DATABASE supabase OWNER TO supabase_admin;
GRANT ALL PRIVILEGES ON DATABASE _supabase TO supabase_admin;
ALTER DATABASE _supabase OWNER TO supabase_admin;

\c supabase
ALTER SCHEMA public OWNER TO supabase_admin;
GRANT ALL ON SCHEMA public TO supabase_admin;

\c _supabase
ALTER SCHEMA _analytics OWNER TO supabase_admin;
GRANT ALL ON SCHEMA _analytics TO supabase_admin;

\c postgres

-- supabase_auth_admin (used by GoTrue/Auth service)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    CREATE ROLE supabase_auth_admin WITH LOGIN NOINHERIT PASSWORD 'Ua2o3hFDi9gS7ih8Nzkaicdt';
  END IF;
END $$;
GRANT ALL PRIVILEGES ON DATABASE supabase TO supabase_auth_admin;

\c supabase
CREATE SCHEMA IF NOT EXISTS auth AUTHORIZATION supabase_auth_admin;
GRANT ALL ON SCHEMA auth TO supabase_auth_admin;

\c postgres

-- supabase_storage_admin (used by Storage API service)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_storage_admin') THEN
    CREATE ROLE supabase_storage_admin WITH LOGIN NOINHERIT PASSWORD 'Ua2o3hFDi9gS7ih8Nzkaicdt';
  END IF;
END $$;
GRANT ALL PRIVILEGES ON DATABASE supabase TO supabase_storage_admin;

\c supabase
CREATE SCHEMA IF NOT EXISTS storage AUTHORIZATION supabase_storage_admin;
GRANT ALL ON SCHEMA storage TO supabase_storage_admin;

\c postgres

-- authenticator (used by PostgREST; impersonates anon/authenticated roles)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator WITH LOGIN NOINHERIT PASSWORD 'Ua2o3hFDi9gS7ih8Nzkaicdt';
  END IF;
END $$;
GRANT ALL PRIVILEGES ON DATABASE supabase TO authenticator;

\c postgres

-- hatchet_user
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hatchet_user') THEN
    CREATE ROLE hatchet_user WITH LOGIN PASSWORD 'FLMKvjG6wcX8ChTTZPSl3WS0';
  END IF;
END $$;
GRANT ALL PRIVILEGES ON DATABASE hatchet TO hatchet_user;
ALTER DATABASE hatchet OWNER TO hatchet_user;

\c hatchet
ALTER SCHEMA public OWNER TO hatchet_user;
GRANT ALL ON SCHEMA public TO hatchet_user;

\c postgres

-- langfuse_user
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'langfuse_user') THEN
    CREATE ROLE langfuse_user WITH LOGIN PASSWORD 'DbAm2Q92FDgVZ4CbRogTig6E';
  END IF;
END $$;
GRANT ALL PRIVILEGES ON DATABASE langfuse TO langfuse_user;
ALTER DATABASE langfuse OWNER TO langfuse_user;

\c langfuse
ALTER SCHEMA public OWNER TO langfuse_user;
GRANT ALL ON SCHEMA public TO langfuse_user;

\c postgres

-- n8n_user
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'n8n_user') THEN
    CREATE ROLE n8n_user WITH LOGIN PASSWORD 'YcK97WSE1ZbqnNt7YBoepmNO';
  END IF;
END $$;
GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n_user;
ALTER DATABASE n8n OWNER TO n8n_user;

\c n8n
ALTER SCHEMA public OWNER TO n8n_user;
GRANT ALL ON SCHEMA public TO n8n_user;

\c postgres

-- dify_user
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dify_user') THEN
    CREATE ROLE dify_user WITH LOGIN PASSWORD 'I8BMih9xIH5m3Y76ZjAv22bs';
  END IF;
END $$;
GRANT ALL PRIVILEGES ON DATABASE dify TO dify_user;
ALTER DATABASE dify OWNER TO dify_user;

\c dify
ALTER SCHEMA public OWNER TO dify_user;
GRANT ALL ON SCHEMA public TO dify_user;

\c postgres

-- outline_user
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'outline_user') THEN
    CREATE ROLE outline_user WITH LOGIN PASSWORD 'R9CatEttuWVr3PlXr8qD1t5K';
  END IF;
END $$;
GRANT ALL PRIVILEGES ON DATABASE outline TO outline_user;
ALTER DATABASE outline OWNER TO outline_user;

\c outline
ALTER SCHEMA public OWNER TO outline_user;
GRANT ALL ON SCHEMA public TO outline_user;

\c postgres

-- litellm_user
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'litellm_user') THEN
    CREATE ROLE litellm_user WITH LOGIN PASSWORD '6G4XfERKA2hXmmEN9MAiW5J9';
  END IF;
END $$;
GRANT ALL PRIVILEGES ON DATABASE litellm TO litellm_user;
ALTER DATABASE litellm OWNER TO litellm_user;

\c litellm
ALTER SCHEMA public OWNER TO litellm_user;
GRANT ALL ON SCHEMA public TO litellm_user;

\c postgres

-- gitlab_user
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'gitlab_user') THEN
    CREATE ROLE gitlab_user WITH LOGIN PASSWORD 'aSu9IbMB1xlZRhd9fzYih03q';
  END IF;
END $$;
GRANT ALL PRIVILEGES ON DATABASE gitlab TO gitlab_user;
ALTER DATABASE gitlab OWNER TO gitlab_user;

\c gitlab
ALTER SCHEMA public OWNER TO gitlab_user;
GRANT ALL ON SCHEMA public TO gitlab_user;

\c postgres
