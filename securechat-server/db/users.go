package db

import (
	"database/sql"
	"fmt"
	"time"
)

type User struct {
	UserID       string
	DisplayName  string
	PublicKey    []byte
	SignPublic   []byte
	RegisteredAt int64
	LastSeen     *int64
}

func CreateUser(db *sql.DB, u *User) error {
	u.RegisteredAt = time.Now().Unix()
	_, err := db.Exec(`
		INSERT INTO users (user_id, display_name, public_key, sign_public, registered_at)
		VALUES (?, ?, ?, ?, ?)`,
		u.UserID, u.DisplayName, u.PublicKey, u.SignPublic, u.RegisteredAt,
	)
	if err != nil {
		return fmt.Errorf("create user: %w", err)
	}
	return nil
}

func GetUser(db *sql.DB, userID string) (*User, error) {
	u := &User{}
	err := db.QueryRow(`
		SELECT user_id, display_name, public_key, sign_public, registered_at, last_seen
		FROM users WHERE user_id = ?`, userID,
	).Scan(&u.UserID, &u.DisplayName, &u.PublicKey, &u.SignPublic, &u.RegisteredAt, &u.LastSeen)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get user: %w", err)
	}
	return u, nil
}

func SearchUsers(db *sql.DB, query string, limit int) ([]*User, error) {
	rows, err := db.Query(`
		SELECT user_id, display_name, public_key, sign_public, registered_at
		FROM users WHERE display_name LIKE ? LIMIT ?`,
		"%"+query+"%", limit,
	)
	if err != nil {
		return nil, fmt.Errorf("search users: %w", err)
	}
	defer rows.Close()

	var users []*User
	for rows.Next() {
		u := &User{}
		if err := rows.Scan(&u.UserID, &u.DisplayName, &u.PublicKey, &u.SignPublic, &u.RegisteredAt); err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

func UpdateLastSeen(db *sql.DB, userID string) {
	now := time.Now().Unix()
	db.Exec(`UPDATE users SET last_seen = ? WHERE user_id = ?`, now, userID)
}

func UserKeysMatch(db *sql.DB, userID string, publicKey, signPublic []byte) (bool, error) {
	var pk, sp []byte
	err := db.QueryRow(`SELECT public_key, sign_public FROM users WHERE user_id = ?`, userID).Scan(&pk, &sp)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return string(pk) == string(publicKey) && string(sp) == string(signPublic), nil
}
