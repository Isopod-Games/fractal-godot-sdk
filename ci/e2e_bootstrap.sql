-- Minimal Postgres bootstrap for the SDK end-to-end CI workflow.
--
-- Creates only the two tables the Go collector's auth path needs:
--   SELECT ak.project_id, p.ip_tracking_enabled
--   FROM api_keys ak JOIN projects p ON p.id = ak.project_id
--   WHERE ak.key = $1 AND ak.active = true
--
-- The Rails schema has many more tables; this file deliberately stays
-- minimal so the e2e doesn't need a working `bin/rails db:setup`.

CREATE TABLE IF NOT EXISTS projects (
  id BIGSERIAL PRIMARY KEY,
  name VARCHAR NOT NULL,
  ip_tracking_enabled BOOLEAN DEFAULT false NOT NULL,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS api_keys (
  id BIGSERIAL PRIMARY KEY,
  project_id BIGINT NOT NULL REFERENCES projects(id),
  key VARCHAR NOT NULL UNIQUE,
  active BOOLEAN DEFAULT true NOT NULL,
  description VARCHAR,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS minidump_dedup (
  event_id UUID PRIMARY KEY,
  committed BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMP DEFAULT NOW() NOT NULL
);

INSERT INTO projects (id, name) VALUES (1, 'CI E2E Project')
  ON CONFLICT (id) DO NOTHING;

INSERT INTO api_keys (project_id, key, active, description)
  VALUES (1, 'ci-e2e-fixed-api-key', true, 'CI integration test key')
  ON CONFLICT (key) DO NOTHING;
