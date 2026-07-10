package db

import (
	"database/sql"
	"fmt"
	"os"
	"strings"
	"sync"

	sqlite3 "github.com/mutecomm/go-sqlcipher/v4"
)

var registerEnc sync.Once

// Open opens the SQLite database. When [key] is non-empty the database is
// encrypted at rest with SQLCipher (AES-256); the key is supplied at startup
// (SECURECHAT_DB_KEY) and never stored on disk. A pre-existing plaintext DB is
// migrated to encrypted transparently (a .plaintext.bak is kept).
func Open(path, key string) (*sql.DB, error) {
	if key != "" {
		esc := strings.ReplaceAll(key, "'", "''")
		registerEnc.Do(func() {
			sql.Register("sqlite3-enc", &sqlite3.SQLiteDriver{
				ConnectHook: func(conn *sqlite3.SQLiteConn) error {
					// PRAGMA key MUST be the first statement on the connection,
					// before any other pragma or query, or SQLCipher can't set up.
					if _, err := conn.Exec(fmt.Sprintf("PRAGMA key = '%s';", esc), nil); err != nil {
						return err
					}
					if _, err := conn.Exec("PRAGMA journal_mode=WAL;", nil); err != nil {
						return err
					}
					_, err := conn.Exec("PRAGMA foreign_keys=ON;", nil)
					return err
				},
			})
		})
		if err := ensureEncrypted(path, esc); err != nil {
			return nil, err
		}
	}

	var database *sql.DB
	var err error
	if key != "" {
		database, err = sql.Open("sqlite3-enc", path) // pragmas applied in the hook
	} else {
		database, err = sql.Open("sqlite3", path+"?_journal_mode=WAL&_foreign_keys=on")
	}
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	database.SetMaxOpenConns(1)

	// Verify the key actually decrypts the database.
	if key != "" {
		if _, err := database.Exec("SELECT count(*) FROM sqlite_master"); err != nil {
			database.Close()
			return nil, fmt.Errorf("cannot open encrypted DB (wrong SECURECHAT_DB_KEY?): %w", err)
		}
	}

	if err := migrate(database); err != nil {
		database.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return database, nil
}

// ensureEncrypted migrates a pre-existing plaintext DB to an encrypted one.
// escKey is the SQLCipher key with single quotes already escaped.
func ensureEncrypted(path, escKey string) error {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil // fresh install — the encrypted DB is created on open
	}

	// Is the existing file plaintext? (Opening it without a key succeeds.)
	pdb, err := sql.Open("sqlite3", path)
	if err != nil {
		return err
	}
	if _, err := pdb.Exec("SELECT count(*) FROM sqlite_master"); err != nil {
		pdb.Close()
		return nil // already encrypted (or unreadable) — leave it to the keyed open
	}

	// Plaintext → export into an encrypted copy, then swap files.
	encPath := path + ".enc"
	os.Remove(encPath)
	escEnc := strings.ReplaceAll(encPath, "'", "''")
	if _, err := pdb.Exec(fmt.Sprintf("ATTACH DATABASE '%s' AS enc KEY '%s';", escEnc, escKey)); err != nil {
		pdb.Close()
		return fmt.Errorf("db migrate attach: %w", err)
	}
	if _, err := pdb.Exec("SELECT sqlcipher_export('enc');"); err != nil {
		pdb.Close()
		return fmt.Errorf("db migrate export: %w", err)
	}
	pdb.Exec("DETACH DATABASE enc;")
	pdb.Close()

	// Keep the plaintext as a backup; swap in the encrypted file.
	if err := os.Rename(path, path+".plaintext.bak"); err != nil {
		return fmt.Errorf("db migrate backup: %w", err)
	}
	if err := os.Rename(encPath, path); err != nil {
		return fmt.Errorf("db migrate swap: %w", err)
	}
	return nil
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

		CREATE TABLE IF NOT EXISTS federation_peers (
			id        INTEGER PRIMARY KEY AUTOINCREMENT,
			url       TEXT NOT NULL UNIQUE,
			name      TEXT NOT NULL DEFAULT '',
			secret    TEXT NOT NULL DEFAULT '',
			added_at  INTEGER NOT NULL,
			last_seen INTEGER
		);

		CREATE TABLE IF NOT EXISTS room_admins (
			room_id TEXT NOT NULL,
			user_id TEXT NOT NULL,
			role    TEXT NOT NULL DEFAULT 'admin',  -- 'owner' | 'admin'
			PRIMARY KEY (room_id, user_id)
		);

		CREATE TABLE IF NOT EXISTS room_bans (
			room_id TEXT NOT NULL,
			user_id TEXT NOT NULL,
			until   INTEGER NOT NULL DEFAULT 0,     -- 0 = permanent, else unix ts
			PRIMARY KEY (room_id, user_id)
		);

		CREATE INDEX IF NOT EXISTS idx_offline_recipient ON offline_messages(recipient_id);
		CREATE INDEX IF NOT EXISTS idx_offline_expires   ON offline_messages(expires_at);
		CREATE INDEX IF NOT EXISTS idx_room_members_room ON room_members(room_id);
		CREATE INDEX IF NOT EXISTS idx_invites_expires   ON invites(expires_at);
	`)
	if err != nil {
		return err
	}

	// Public rooms flag (idempotent — ignore "duplicate column" on re-runs).
	db.Exec(`ALTER TABLE rooms ADD COLUMN is_public INTEGER NOT NULL DEFAULT 0`)
	return nil
}
