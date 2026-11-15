-- Scopes tasks to the user who owns them. `App.Tasks` now takes an
-- `App.Accounts.Scope` as its first argument and every task route in
-- `D1Gateway` filters on `user_id`.
--
-- Additive on purpose: the previous version of the app keeps serving traffic
-- while a deploy rolls out, so the column is nullable rather than NOT NULL.
-- Rows written before this migration therefore have a NULL `user_id` and
-- belong to nobody — because every route filters on `user_id`, they become
-- invisible rather than shared. SQLite has no `ADD COLUMN IF NOT EXISTS`, but
-- migrations are applied once and tracked (D1's own table remotely, the
-- `local_migrations` table in `App.D1.LocalGateway`), so this runs once.
ALTER TABLE tasks ADD COLUMN user_id INTEGER REFERENCES users (id) ON DELETE CASCADE;

-- Matches the only read pattern there is now: one user's tasks, newest first.
CREATE INDEX IF NOT EXISTS tasks_user_id_idx ON tasks (user_id, inserted_at DESC, id DESC);
