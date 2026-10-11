CREATE TABLE IF NOT EXISTS schema_versions(version integer PRIMARY KEY, installed_at timestamptz NOT NULL DEFAULT now());
INSERT INTO schema_versions(version) VALUES(1) ON CONFLICT DO NOTHING;
INSERT INTO schema_versions(version) VALUES(2) ON CONFLICT DO NOTHING;
INSERT INTO schema_versions(version) VALUES(3) ON CONFLICT DO NOTHING;
