-- Snuffle backend on D1: drafting review replies with hidden per-install credits, a global daily spend ceiling,
-- one trace row per request, and the App Store purchases that unlock Pro.
-- Only the Worker reaches this database; there is no client access to it.

-- The model in use. Exactly one active row; switching models is inserting a new revision and flipping `active`.
CREATE TABLE model_config (
  revision INTEGER PRIMARY KEY AUTOINCREMENT,
  provider TEXT NOT NULL CHECK (provider IN ('openai', 'anthropic', 'deepseek', 'dashscope', 'openrouter')),
  model TEXT NOT NULL,
  max_output_tokens INTEGER NOT NULL DEFAULT 700 CHECK (max_output_tokens BETWEEN 100 AND 4000),
  temperature REAL CHECK (temperature BETWEEN 0 AND 2),
  input_usd_per_mtok REAL NOT NULL CHECK (input_usd_per_mtok >= 0),
  output_usd_per_mtok REAL NOT NULL CHECK (output_usd_per_mtok >= 0),
  -- Provider-specific request fields merged into the body, e.g. {"reasoning_effort": "low"}.
  extra TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(extra)),
  active INTEGER NOT NULL DEFAULT 0 CHECK (active IN (0, 1)),
  note TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE UNIQUE INDEX model_config_single_active ON model_config (active) WHERE active = 1;

-- Operator-tunable limits.
CREATE TABLE app_config (
  key TEXT PRIMARY KEY,
  value REAL NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
INSERT INTO app_config (key, value) VALUES
  ('daily_usd_ceiling', 5),          -- all installs together, per UTC day
  ('daily_install_credits', 40),     -- drafts per install per UTC day; never shown in the app
  ('max_installs_per_purchase', 3);  -- installs that may share one App Store purchase

-- App Store purchases seen by the server, keyed by the original transaction, and which installs presented them.
CREATE TABLE purchases (
  original_transaction_id TEXT PRIMARY KEY,
  product_id TEXT NOT NULL,
  environment TEXT NOT NULL,
  expires_at TEXT,
  revoked_at TEXT,
  first_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  last_verified_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE purchase_installs (
  original_transaction_id TEXT NOT NULL REFERENCES purchases ON DELETE CASCADE,
  install_id TEXT NOT NULL,
  linked_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (original_transaction_id, install_id)
);

-- One row per drafting request: written before the model is called, completed after. It is the trace and the
-- usage record. Review text is never stored, only its shape.
CREATE TABLE draft_requests (
  request_id TEXT PRIMARY KEY,
  install_id TEXT NOT NULL,
  original_transaction_id TEXT,
  day TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'reserved' CHECK (status IN ('reserved', 'succeeded', 'failed')),
  credits INTEGER NOT NULL DEFAULT 1,
  estimate_usd REAL NOT NULL DEFAULT 0,
  model_revision INTEGER,
  provider TEXT,
  model TEXT,
  review_platform TEXT,
  review_rating INTEGER,
  review_language TEXT,
  review_chars INTEGER,
  input_tokens INTEGER,
  output_tokens INTEGER,
  cost_usd REAL,
  latency_ms INTEGER,
  error TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  finished_at TEXT
);
CREATE INDEX draft_requests_install_day ON draft_requests (install_id, day);
CREATE INDEX draft_requests_day ON draft_requests (day);

-- Running spend per UTC day: settled cost plus estimates of requests still in flight.
CREATE TABLE daily_spend (
  day TEXT PRIMARY KEY,
  cost_usd REAL NOT NULL DEFAULT 0,
  reserved_usd REAL NOT NULL DEFAULT 0
);

-- The spend ledger follows the request rows, so no code path can admit or settle without booking it.
CREATE TRIGGER draft_requests_reserve AFTER INSERT ON draft_requests
BEGIN
  UPDATE daily_spend SET reserved_usd = reserved_usd + NEW.estimate_usd WHERE day = NEW.day;
END;

-- Completing a request releases its estimate and books the real cost. Failed requests keep the cost the provider
-- may still charge, while their credit goes back to the install (failed rows are not counted).
CREATE TRIGGER draft_requests_settle AFTER UPDATE OF status ON draft_requests
WHEN OLD.status = 'reserved' AND NEW.status <> 'reserved'
BEGIN
  UPDATE daily_spend
     SET reserved_usd = max(0, reserved_usd - OLD.estimate_usd),
         cost_usd = cost_usd + coalesce(NEW.cost_usd, 0)
   WHERE day = OLD.day;
END;

-- For operators (wrangler d1 execute snuffle --remote --command "SELECT * FROM usage_by_day LIMIT 7").
CREATE VIEW usage_by_day AS
SELECT day,
       sum(status = 'succeeded') AS drafts,
       sum(status = 'failed') AS failures,
       count(DISTINCT install_id) AS installs,
       coalesce(sum(input_tokens), 0) AS input_tokens,
       coalesce(sum(output_tokens), 0) AS output_tokens,
       round(coalesce(sum(cost_usd), 0), 6) AS cost_usd,
       round(avg(latency_ms)) AS avg_latency_ms
  FROM draft_requests
 GROUP BY day
 ORDER BY day DESC;

CREATE VIEW usage_by_install_today AS
SELECT install_id,
       original_transaction_id,
       sum(status <> 'failed') AS credits_used,
       round(coalesce(sum(cost_usd), 0), 6) AS cost_usd,
       max(created_at) AS last_request
  FROM draft_requests
 WHERE day = strftime('%Y-%m-%d', 'now')
 GROUP BY install_id, original_transaction_id
 ORDER BY credits_used DESC;
