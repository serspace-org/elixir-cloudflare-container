-- Chat demo table. Backs the WebSocket/Channel smoke test (see README,
-- "Chat (WebSocket + Channels) demo"). History is persisted so a reconnect
-- or a container restart can be told apart from message loss.
CREATE TABLE IF NOT EXISTS messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  room TEXT NOT NULL CHECK (length(trim(room)) > 0),
  nickname TEXT NOT NULL CHECK (length(trim(nickname)) > 0),
  body TEXT NOT NULL CHECK (length(trim(body)) > 0),
  inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS messages_room_id_idx ON messages (room, id);
