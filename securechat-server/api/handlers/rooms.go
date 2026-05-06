package handlers

import (
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"net/http"

	"github.com/securechat/server/db"
)

type createRoomRequest struct {
	RoomID     string `json:"room_id"`
	RoomName   string `json:"room_name"`
	Salt       string `json:"salt"`       // hex-encoded 16 bytes
	MaxMembers int    `json:"max_members"`
	ExpiresAt  *int64 `json:"expires_at"` // optional Unix timestamp
}

type roomResponse struct {
	RoomID      string  `json:"room_id"`
	RoomName    string  `json:"room_name"`
	Salt        string  `json:"salt"`
	CreatedAt   int64   `json:"created_at"`
	MaxMembers  int     `json:"max_members"`
	ExpiresAt   *int64  `json:"expires_at,omitempty"`
	MemberCount int     `json:"member_count"`
}

func CreateRoom(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
			return
		}

		userID, _ := r.Context().Value(ContextUserID).(string)

		var req createRoomRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_json", "Invalid JSON body")
			return
		}

		if req.RoomID == "" || req.RoomName == "" || req.Salt == "" {
			writeError(w, http.StatusBadRequest, "missing_fields", "room_id, room_name, salt required")
			return
		}

		salt, err := hex.DecodeString(req.Salt)
		if err != nil || len(salt) != 16 {
			writeError(w, http.StatusBadRequest, "invalid_salt", "salt must be 16-byte hex")
			return
		}

		// Idempotent: if room_id already exists, return it
		existing, err := db.GetRoom(database, req.RoomID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Database error")
			return
		}
		if existing != nil {
			writeJSON(w, http.StatusOK, roomResponse{
				RoomID:    existing.RoomID,
				RoomName:  existing.RoomName,
				Salt:      hex.EncodeToString(existing.Salt),
				CreatedAt: existing.CreatedAt,
				MaxMembers: existing.MaxMembers,
				ExpiresAt: existing.ExpiresAt,
			})
			return
		}

		room := &db.Room{
			RoomID:     req.RoomID,
			RoomName:   req.RoomName,
			Salt:       salt,
			CreatedBy:  userID,
			MaxMembers: req.MaxMembers,
			ExpiresAt:  req.ExpiresAt,
		}
		if err := db.CreateRoom(database, room); err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Could not create room")
			return
		}

		writeJSON(w, http.StatusOK, roomResponse{
			RoomID:    room.RoomID,
			RoomName:  room.RoomName,
			Salt:      hex.EncodeToString(room.Salt),
			CreatedAt: room.CreatedAt,
			MaxMembers: room.MaxMembers,
			ExpiresAt: room.ExpiresAt,
		})
	}
}

func GetRoom(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		roomID := r.PathValue("room_id")
		if roomID == "" {
			writeError(w, http.StatusBadRequest, "missing_room_id", "room_id required")
			return
		}

		room, err := db.GetRoom(database, roomID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Database error")
			return
		}
		if room == nil {
			writeError(w, http.StatusNotFound, "not_found", "Room not found")
			return
		}

		writeJSON(w, http.StatusOK, roomResponse{
			RoomID:      room.RoomID,
			RoomName:    room.RoomName,
			Salt:        hex.EncodeToString(room.Salt),
			CreatedAt:   room.CreatedAt,
			MaxMembers:  room.MaxMembers,
			ExpiresAt:   room.ExpiresAt,
			MemberCount: room.MemberCount,
		})
	}
}

func SearchRooms(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query().Get("q")
		if q == "" {
			writeError(w, http.StatusBadRequest, "missing_q", "Query parameter q required")
			return
		}

		rooms, err := db.SearchRooms(database, q, 20)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Database error")
			return
		}

		results := make([]roomResponse, 0, len(rooms))
		for _, room := range rooms {
			results = append(results, roomResponse{
				RoomID:    room.RoomID,
				RoomName:  room.RoomName,
				Salt:      hex.EncodeToString(room.Salt),
				CreatedAt: room.CreatedAt,
				MaxMembers: room.MaxMembers,
			})
		}
		writeJSON(w, http.StatusOK, results)
	}
}
