-- Rooms become rows, so a chat can belong to a user and be shared with
-- others the way tasks belong to a user (migration 0004).
--
-- The slug stays the external identifier — it is what `messages.room`
-- already stores, what the URL and the channel topic carry, and what
-- `App.Chat.valid_room?/1` validates — so messages keep joining rooms by
-- slug and no message rows need backfilling.
--
-- Crucially, a room with no row here is a *link* room: anyone with the slug
-- may read and write, which is exactly the behavior every room had before
-- this migration. Chat requires a logged-in account either way (migration
-- 0005), so "anyone" means any signed-in user holding the slug. That is why
-- there is no backfill — `lobby`, the smoke test's room and every room
-- opened by slug keep working with no row at all. A row only exists once a
-- user creates (or claims) the slug, and only then can the room be private.
--
--   * `visibility = 'link'`  — anyone with the slug, i.e. the old behavior.
--   * `visibility = 'private'` — the owner and members only.
--
-- Deleting the owner cascades the row away, which deliberately reverts the
-- room to an unowned link room rather than orphaning a private room nobody
-- can ever open again.
CREATE TABLE IF NOT EXISTS rooms (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slug TEXT NOT NULL CHECK (length(trim(slug)) > 0 AND length(slug) <= 64),
  user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  name TEXT CHECK (name IS NULL OR (length(trim(name)) > 0 AND length(name) <= 160)),
  visibility TEXT NOT NULL DEFAULT 'link' CHECK (visibility IN ('link', 'private')),
  inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- A slug addresses at most one room; a conflicting create answers 409
-- (`{:error, :conflict}` in App.D1) and `App.Chat` retries with a new slug.
CREATE UNIQUE INDEX IF NOT EXISTS rooms_slug_idx ON rooms (slug);

-- "My rooms", newest first.
CREATE INDEX IF NOT EXISTS rooms_user_id_idx ON rooms (user_id, inserted_at DESC, id DESC);

-- Who a room is shared with. The owner is not a member — ownership is the
-- `rooms.user_id` column — so the authorization predicate is
-- owner OR member OR link visibility.
CREATE TABLE IF NOT EXISTS room_memberships (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  room_id INTEGER NOT NULL REFERENCES rooms (id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Sharing twice with the same account is a 409, not a second row.
CREATE UNIQUE INDEX IF NOT EXISTS room_memberships_room_user_idx
  ON room_memberships (room_id, user_id);

-- "Shared with me".
CREATE INDEX IF NOT EXISTS room_memberships_user_idx
  ON room_memberships (user_id, room_id);
