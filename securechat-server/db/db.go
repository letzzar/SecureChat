package db

import (
	"database/sql"
	"fmt"

	_ "github.com/mattn/go-sqlite3"
)

func Open(path string) (*sql.DB, error) {
	database, err := sql.Open("sqlite3", path+"?_journal_mode=WAL&_foreign_keys=on")
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}

	database.SetMaxOpenConns(1)

	if err := migrate(database); err != nil {
		database.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return database, nil
}

func migrate(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS users (
			user_id       TEXT PRIMARY KEY,
			display_name  TEXT NOT NULL,
			public_key    BLOB NOT NULL,
			sign_public   BLOB NOT NULL,
			registered_at INTEGER NOT NULL,
			last_seen     INTEGER
		);

		CREATE TABLE IF NOT EXISTS rooms (
			room_id      TEXT PRIMARY KEY,
			room_name    TEXT NOT NULL,
			salt         BLOB NOT NULL,
			created_by   TEXT NOT NULL,
			created_at   INTEGER NOT NULL,
			max_members  INTEGER DEFAULT 0,
			expires_at   INTEGER
		);

		CREATE TABLE IF NOT EXISTS offline_messages (
			id           INTEGER PRIMARY KEY AUTOINCREMENT,
			recipient_id TEXT NOT NULL,
			msg_type     TEXT NOT NULL DEFAULT 'dm',
			from_id      TEXT NOT NULL DEFAULT '',
			payload      TEXT NOT NULL,
			nonce        TEXT NOT NULL DEFAULT '',
			sig          TEXT NOT NULL DEFAULT '',
			seq          INTEGER NOT NULL DEFAULT 0,
			e_pub        TEXT NOT NULL DEFAULT '',
			created_at   INTEGER NOT NULL,
			expires_at   INTEGER NOT NULL
		);

		CREATE TABLE IF NOT EXISTS room_members (
			room_id   TEXT NOT NULL,
			user_id   TEXT NOT NULL,
			joined_at INTEGER NOT NULL,
			PRIMARY KEY (room_id, user_id)
		);

		CREATE TABLE IF NOT EXISTS invites (
			token      TEXT PRIMARY KEY,
			created_by TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			expires_at INTEGER NOT NULL
		);

		CREATE INDEX IF NOT EXISTS idx_offline_recipient ON offline_messages(recipient_id);
		CREATE INDEX IF NOT EXISTS idx_offline_expires   ON offline_messages(expires_at);
		CREATE INDEX IF NOT EXISTS idx_room_members_room ON room_members(room_id);
		CREATE INDEX IF NOT EXISTS idx_invites_expires   ON invites(expires_at);
	`)
	return err
}
