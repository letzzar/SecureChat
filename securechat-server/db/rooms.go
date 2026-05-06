package db

import (
	"database/sql"
	"fmt"
	"time"
)

type Room struct {
	RoomID      string
	RoomName    string
	Salt        []byte
	CreatedBy   string
	CreatedAt   int64
	MaxMembers  int
	ExpiresAt   *int64
	MemberCount int // active WebSocket subscribers (runtime value)
}

func CreateRoom(db *sql.DB, r *Room) error {
	r.CreatedAt = time.Now().Unix()
	_, err := db.Exec(`
		INSERT INTO rooms (room_id, room_name, salt, created_by, created_at, max_members, expires_at)
		VALUES (?,?,?,?,?,?,?)`,
		r.RoomID, r.RoomName, r.Salt, r.CreatedBy, r.CreatedAt, r.MaxMembers, r.ExpiresAt,
	)
	if err != nil {
		return fmt.Errorf("create room: %w", err)
	}
	return nil
}

func GetRoom(db *sql.DB, roomID string) (*Room, error) {
	r := &Room{}
	err := db.QueryRow(`
		SELECT room_id, room_name, salt, created_by, created_at, max_members, expires_at
		FROM rooms WHERE room_id = ?`, roomID,
	).Scan(&r.RoomID, &r.RoomName, &r.Salt, &r.CreatedBy, &r.CreatedAt, &r.MaxMembers, &r.ExpiresAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get room: %w", err)
	}
	return r, nil
}

func SearchRooms(db *sql.DB, query string, limit int) ([]*Room, error) {
	rows, err := db.Query(`
		SELECT room_id, room_name, salt, created_at, max_members
		FROM rooms WHERE room_name LIKE ? LIMIT ?`,
		"%"+query+"%", limit,
	)
	if err != nil {
		return nil, fmt.Errorf("search rooms: %w", err)
	}
	defer rows.Close()

	var rooms []*Room
	for rows.Next() {
		r := &Room{}
		if err := rows.Scan(&r.RoomID, &r.RoomName, &r.Salt, &r.CreatedAt, &r.MaxMembers); err != nil {
			return nil, err
		}
		rooms = append(rooms, r)
	}
	return rooms, rows.Err()
}

func RoomExists(db *sql.DB, roomID string) (bool, error) {
	var count int
	err := db.QueryRow(`SELECT COUNT(1) FROM rooms WHERE room_id = ?`, roomID).Scan(&count)
	return count > 0, err
}

func DeleteExpiredRooms(db *sql.DB) error {
	_, err := db.Exec(`DELETE FROM rooms WHERE expires_at IS NOT NULL AND expires_at <= ?`, time.Now().Unix())
	return err
}
