package db

import (
	"database/sql"
	"fmt"
	"time"
)

// RoomMember is a member of a public room, with their moderation role.
type RoomMember struct {
	UserID      string
	DisplayName string
	Role        string // "owner" | "admin" | "" (regular member)
}

// SearchPublicRooms lists public rooms whose name matches query (empty = all),
// with their current member count.
func SearchPublicRooms(db *sql.DB, query string, limit int) ([]*Room, error) {
	rows, err := db.Query(`
		SELECT r.room_id, r.room_name, r.created_by, r.created_at,
		       (SELECT COUNT(1) FROM room_members m WHERE m.room_id = r.room_id)
		FROM rooms r
		WHERE r.is_public = 1 AND r.room_name LIKE ?
		ORDER BY r.room_name LIMIT ?`,
		"%"+query+"%", limit,
	)
	if err != nil {
		return nil, fmt.Errorf("search public rooms: %w", err)
	}
	defer rows.Close()

	var rooms []*Room
	for rows.Next() {
		r := &Room{IsPublic: true}
		if err := rows.Scan(&r.RoomID, &r.RoomName, &r.CreatedBy, &r.CreatedAt, &r.MemberCount); err != nil {
			return nil, err
		}
		rooms = append(rooms, r)
	}
	return rooms, rows.Err()
}

// ── Membership ────────────────────────────────────────────────────────────────

func AddRoomMember(db *sql.DB, roomID, userID string) error {
	_, err := db.Exec(
		`INSERT OR IGNORE INTO room_members (room_id, user_id, joined_at) VALUES (?,?,?)`,
		roomID, userID, time.Now().Unix(),
	)
	return err
}

func RemoveRoomMember(db *sql.DB, roomID, userID string) error {
	_, err := db.Exec(`DELETE FROM room_members WHERE room_id = ? AND user_id = ?`, roomID, userID)
	return err
}

func IsRoomMember(db *sql.DB, roomID, userID string) (bool, error) {
	var n int
	err := db.QueryRow(`SELECT COUNT(1) FROM room_members WHERE room_id = ? AND user_id = ?`, roomID, userID).Scan(&n)
	return n > 0, err
}

func RoomMembersDetailed(db *sql.DB, roomID string) ([]RoomMember, error) {
	rows, err := db.Query(`
		SELECT m.user_id, COALESCE(u.display_name, ''), COALESCE(a.role, '')
		FROM room_members m
		LEFT JOIN users u ON u.user_id = m.user_id
		LEFT JOIN room_admins a ON a.room_id = m.room_id AND a.user_id = m.user_id
		WHERE m.room_id = ?
		ORDER BY CASE COALESCE(a.role,'') WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END,
		         m.joined_at`,
		roomID,
	)
	if err != nil {
		return nil, fmt.Errorf("room members: %w", err)
	}
	defer rows.Close()

	var out []RoomMember
	for rows.Next() {
		var m RoomMember
		if err := rows.Scan(&m.UserID, &m.DisplayName, &m.Role); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// ── Admin roles ───────────────────────────────────────────────────────────────

func SetRoomAdmin(db *sql.DB, roomID, userID, role string) error {
	_, err := db.Exec(
		`INSERT OR REPLACE INTO room_admins (room_id, user_id, role) VALUES (?,?,?)`,
		roomID, userID, role,
	)
	return err
}

func RemoveRoomAdmin(db *sql.DB, roomID, userID string) error {
	// The owner cannot be demoted.
	_, err := db.Exec(`DELETE FROM room_admins WHERE room_id = ? AND user_id = ? AND role != 'owner'`, roomID, userID)
	return err
}

// RoomRole returns "owner", "admin", or "" for a user in a room.
func RoomRole(db *sql.DB, roomID, userID string) (string, error) {
	var role string
	err := db.QueryRow(`SELECT role FROM room_admins WHERE room_id = ? AND user_id = ?`, roomID, userID).Scan(&role)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return role, err
}

func IsRoomAdmin(db *sql.DB, roomID, userID string) (bool, error) {
	role, err := RoomRole(db, roomID, userID)
	return role == "owner" || role == "admin", err
}

// ── Bans ──────────────────────────────────────────────────────────────────────

// BanRoomUser bans a user until [until] (0 = permanent) and drops their
// membership.
func BanRoomUser(db *sql.DB, roomID, userID string, until int64) error {
	if _, err := db.Exec(
		`INSERT OR REPLACE INTO room_bans (room_id, user_id, until) VALUES (?,?,?)`,
		roomID, userID, until,
	); err != nil {
		return err
	}
	return RemoveRoomMember(db, roomID, userID)
}

func UnbanRoomUser(db *sql.DB, roomID, userID string) error {
	_, err := db.Exec(`DELETE FROM room_bans WHERE room_id = ? AND user_id = ?`, roomID, userID)
	return err
}

// IsRoomBanned reports whether a user is currently banned, cleaning up expired
// temporary bans.
func IsRoomBanned(db *sql.DB, roomID, userID string) (bool, error) {
	var until int64
	err := db.QueryRow(`SELECT until FROM room_bans WHERE room_id = ? AND user_id = ?`, roomID, userID).Scan(&until)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if until == 0 {
		return true, nil // permanent
	}
	if until > time.Now().Unix() {
		return true, nil
	}
	// Expired — clean up.
	_ = UnbanRoomUser(db, roomID, userID)
	return false, nil
}
