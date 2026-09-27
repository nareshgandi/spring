-- Idempotent. Run as superuser via stdin:  sudo -u postgres psql < setup.sql
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'repro') THEN
    CREATE ROLE repro LOGIN PASSWORD 'repro';
  END IF;
END $$;

SELECT 'CREATE DATABASE repro OWNER repro'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'repro') \gexec

\c repro
CREATE TABLE IF NOT EXISTS t (id bigserial PRIMARY KEY, v text, ts timestamptz DEFAULT now());
ALTER TABLE t OWNER TO repro;
