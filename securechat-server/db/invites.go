package db

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"time"
)

type Invite struct {
	Token     string
	CreatedBy string
	CreatedAt int64
	ExpiresAt int64
}

// CreateInvite generates a random token and stores it with the given TTL.
func CreateInvite(database *sql.DB, createdBy string, ttl time.Duration) (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	token := hex.EncodeToString(b)
	now := time.Now().Unix()
	_, err := database.Exec(
		`INSERT INTO invites (token, created_by, created_at, expires_at) VALUES (?, ?, ?, ?)`,
		token, createdBy, now, now+int64(ttl.Seconds()),
	)
	return token, err
}

// UseInvite validates and atomically consumes a token.
// Returns true if the token was valid and has been consumed.
func UseInvite(database *sql.DB, token string) (bool, error) {
	res, err := database.Exec(
		`DELETE FROM invites WHERE token = ? AND expires_at > ?`,
		token, time.Now().Unix(),
	)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// CountUsers returns the total number of registered users.
func CountUsers(database *sql.DB) (int, error) {
	var n int
	return n, database.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&n)
}
