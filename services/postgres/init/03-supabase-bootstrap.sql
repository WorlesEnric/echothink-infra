\set ON_ERROR_STOP on

\c supabase

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;
END $$;

-- Schemas (auth and storage are owned by their dedicated admin roles, created in 02-roles.sql)
CREATE SCHEMA IF NOT EXISTS _realtime AUTHORIZATION supabase_admin;

-- Public schema grants
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA _realtime TO supabase_admin;

-- supabase_admin can impersonate application roles
GRANT anon TO supabase_admin;
GRANT authenticated TO supabase_admin;
GRANT service_role TO supabase_admin;

-- authenticator can impersonate application roles (required by PostgREST)
GRANT anon TO authenticator;
GRANT authenticated TO authenticator;
GRANT service_role TO authenticator;
GRANT supabase_admin TO authenticator;

-- supabase_auth_admin needs access to public schema
GRANT USAGE ON SCHEMA public TO supabase_auth_admin;

-- supabase_storage_admin needs access to public schema
GRANT USAGE ON SCHEMA public TO supabase_storage_admin;
