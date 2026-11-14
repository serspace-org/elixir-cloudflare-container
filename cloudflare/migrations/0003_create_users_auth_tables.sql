-- Accounts tables for `mix phx.gen.auth`-generated authentication, translated
-- from the generator's Ecto/Postgres migration to D1 (SQLite).
--
-- Differences from the generated Postgres schema, all forced by D1:
--
--   * `citext` does not exist, so emails are stored as written and compared
--     case-insensitively: the unique index is on `lower(email)` and every
--     lookup in `D1Gateway` binds `lower(?1)`.
--   * Timestamps are TEXT in SQLite's `CURRENT_TIMESTAMP` format
--     ("YYYY-MM-DD HH:MM:SS", always UTC). `App.Accounts` parses them into
--     `DateTime`s; the gateway writes them with `CURRENT_TIMESTAMP` or binds
--     a string in the same format.
--   * Token bytes are stored as lowercase hex rather than a bytea/BLOB, so
--     they survive the JSON hop between the container and the gateway.
--     `App.D1` encodes and decodes; `App.Accounts.UserToken` still works in
--     raw binaries.
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT NOT NULL CHECK (length(trim(email)) > 0 AND length(email) <= 160),
  hashed_password TEXT,
  confirmed_at TEXT,
  inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Stands in for Postgres `citext` + `create unique_index(:users, [:email])`.
CREATE UNIQUE INDEX IF NOT EXISTS users_email_idx ON users (lower(email));

CREATE TABLE IF NOT EXISTS users_tokens (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  token TEXT NOT NULL CHECK (length(token) = 64),
  context TEXT NOT NULL CHECK (length(trim(context)) > 0),
  sent_to TEXT,
  authenticated_at TEXT,
  inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS users_tokens_user_id_idx ON users_tokens (user_id);

CREATE UNIQUE INDEX IF NOT EXISTS users_tokens_context_token_idx
  ON users_tokens (context, token);
