package db

import (
	"database/sql"
	"fmt"
	"log"
	"net/url"
	"os"
	"strings"

	_ "github.com/mutecomm/go-sqlcipher/v4"
)

// Open opens the SQLite database. When [key] is non-empty the database is
// encrypted at rest with SQLCipher (AES-256); the key is supplied at startup
// (SECURECHAT_DB_KEY) and never stored on disk. A pre-existing plaintext DB is
// migrated to encrypted transparently (a .plaintext.bak is kept).
func Open(path, key string) (*sql.DB, error) {
	// Trim surrounding whitespace/newlines: a key sourced from an env var, a
	// Docker secret or an .env file often carries a trailing newline, which
	// would silently change the key and make the DB undecryptable.
	key = strings.TrimSpace(key)

	dsn := path + "?_journal_mode=WAL&_foreign_keys=on"
	if key != "" {
		// Apply the SQLCipher key through the DSN (_pragma_key). The driver runs
		// `PRAGMA key` at the C level right after opening the connection — before
		// the pager reads the first page — which is the only reliable place to set
		// it. Doing it later via a ConnectHook produces a DB that encrypts on
		// create but cannot be reopened ("file is not a database").
		dsn = path + "?_pragma_key=" + url.QueryEscape(key) + "&_journal_mode=WAL&_foreign_keys=on"
		if err := ensureEncrypted(path, strings.ReplaceAll(key, "'", "''")); err != nil {
			return nil, err
		}
	}

	database, err := sql.Open("sqlite3", dsn)
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	database.SetMaxOpenConns(1)

	// Verify the key actually decrypts the database.
	if key != "" {
		if _, err := database.Exec("SELECT count(*) FROM sqlite_master"); err != nil {
			database.Close()
			return nil, fmt.Errorf("cannot open encrypted database %s with the provided SECURECHAT_DB_KEY: %w. "+
				"The file is either encrypted with a different key or corrupt. "+
				"Check the key has no stray quotes/whitespace, and if a %s.plaintext.bak exists you can restore it and let the migration run again", path, err, path)
		}
		log.Printf("database: opened %s (encrypted at rest, SQLCipher AES-256)", path)
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
		// Not readable as plaintext: it is already encrypted (or corrupt). Do not
		// migrate — the keyed open will decrypt it if the key matches.
		log.Printf("database: %s is not plaintext — assuming already encrypted; opening with the provided key", path)
		return nil
	}

	// Plaintext → export into an encrypted copy, then swap files.
	log.Printf("database: %s is plaintext — migrating to encrypted at rest (SQLCipher AES-256)…", path)
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
	log.Printf("database: migration complete — encrypted DB in place; plaintext backup kept at %s.plaintext.bak (delete it once you have verified the server works)", path)
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
