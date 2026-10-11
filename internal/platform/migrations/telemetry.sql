CREATE TABLE IF NOT EXISTS telemetry_exports(seq bigint PRIMARY KEY REFERENCES events(seq), exported_at timestamptz NOT NULL DEFAULT now());
