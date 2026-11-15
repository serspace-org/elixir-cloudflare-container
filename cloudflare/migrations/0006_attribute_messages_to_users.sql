-- Attributes a message to the account that sent it, when there was one.
--
-- Nullable on purpose, twice over: link rooms accept anonymous senders, and
-- — as with `tasks.user_id` in migration 0004 — the previous version of the
-- app keeps serving traffic while a deploy rolls out, so the column must be
-- additive. `ON DELETE SET NULL` rather than CASCADE: deleting an account
-- must not silently rewrite other people's transcripts.
ALTER TABLE messages ADD COLUMN user_id INTEGER REFERENCES users (id) ON DELETE SET NULL;
