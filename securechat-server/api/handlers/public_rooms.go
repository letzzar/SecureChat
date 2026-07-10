package handlers

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"time"

	"github.com/securechat/server/config"
	"github.com/securechat/server/db"
	"github.com/securechat/server/federation"
)

func randomRoomID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

type publicRoomResponse struct {
	RoomID      string `json:"room_id"`
	RoomName    string `json:"room_name"`
	CreatedBy   string `json:"created_by,omitempty"`
	CreatedAt   int64  `json:"created_at,omitempty"`
	MemberCount int    `json:"member_count"`
	IsPublic    bool   `json:"is_public"`
	ServerURL   string `json:"server_url,omitempty"` // non-empty = hosted on a federated peer
}

// CreatePublicRoom creates an open, server-visible room and makes the caller its
// owner (and first member).
func CreatePublicRoom(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID, _ := r.Context().Value(ContextUserID).(string)

		var req struct {
			RoomName string `json:"room_name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.RoomName == "" {
			writeError(w, http.StatusBadRequest, "invalid_request", "room_name required")
			return
		}

		room := &db.Room{
			RoomID:    randomRoomID(),
			RoomName:  req.RoomName,
			Salt:      []byte{},
			CreatedBy: userID,
			IsPublic:  true,
		}
		if err := db.CreateRoom(database, room); err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Could not create room")
			return
		}
		_ = db.SetRoomAdmin(database, room.RoomID, userID, "owner")
		_ = db.AddRoomMember(database, room.RoomID, userID)

		writeJSON(w, http.StatusOK, publicRoomResponse{
			RoomID: room.RoomID, RoomName: room.RoomName, CreatedBy: userID,
			CreatedAt: room.CreatedAt, MemberCount: 1, IsPublic: true,
		})
	}
}

// SearchPublicRooms lists/searches public rooms (q optional). In mesh mode it
// also fans out to federated peers and includes their public rooms, tagged with
// server_url.
func SearchPublicRooms(cfg *config.Config, fedClient *federation.Client, database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query().Get("q")
		rooms, err := db.SearchPublicRooms(database, q, 50)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Database error")
			return
		}
		out := make([]publicRoomResponse, 0, len(rooms))
		for _, rm := range rooms {
			out = append(out, publicRoomResponse{
				RoomID: rm.RoomID, RoomName: rm.RoomName, CreatedBy: rm.CreatedBy,
				CreatedAt: rm.CreatedAt, MemberCount: rm.MemberCount, IsPublic: true,
			})
		}

		// Cross-server discovery: aggregate public rooms from federated peers.
		if cfg.IsMesh() && fedClient != nil {
			peers, _ := db.GetFederationPeers(database)
			if len(peers) > 0 {
				for _, fr := range fedClient.SearchPublicRooms(peers, q) {
					out = append(out, publicRoomResponse{
						RoomID: fr.RoomID, RoomName: fr.RoomName,
						MemberCount: fr.MemberCount, IsPublic: true,
						ServerURL: fr.ServerURL,
					})
				}
			}
		}

		writeJSON(w, http.StatusOK, out)
	}
}

// JoinPublicRoom adds the caller to a public room (if not banned).
func JoinPublicRoom(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID, _ := r.Context().Value(ContextUserID).(string)
		roomID := r.PathValue("room_id")

		room, err := db.GetRoom(database, roomID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Database error")
			return
		}
		if room == nil || !room.IsPublic {
			writeError(w, http.StatusNotFound, "not_found", "Public room not found")
			return
		}
		banned, _ := db.IsRoomBanned(database, roomID, userID)
		if banned {
			writeError(w, http.StatusForbidden, "banned", "You are banned from this room")
			return
		}
		if err := db.AddRoomMember(database, roomID, userID); err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Could not join")
			return
		}
		writeJSON(w, http.StatusOK, publicRoomResponse{
			RoomID: room.RoomID, RoomName: room.RoomName, IsPublic: true,
		})
	}
}

// RoomMembers lists a public room's members with their roles (members only).
func RoomMembers(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID, _ := r.Context().Value(ContextUserID).(string)
		roomID := r.PathValue("room_id")

		isMember, _ := db.IsRoomMember(database, roomID, userID)
		if !isMember {
			writeError(w, http.StatusForbidden, "not_member", "Join the room first")
			return
		}
		members, err := db.RoomMembersDetailed(database, roomID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Database error")
			return
		}
		type memberJSON struct {
			UserID      string `json:"user_id"`
			DisplayName string `json:"display_name"`
			Role        string `json:"role"`
		}
		out := make([]memberJSON, 0, len(members))
		for _, m := range members {
			out = append(out, memberJSON{m.UserID, m.DisplayName, m.Role})
		}
		writeJSON(w, http.StatusOK, out)
	}
}

// requireAdmin returns the caller's role if they can moderate the room, else "".
func requireAdmin(database *sql.DB, roomID, userID string) string {
	role, _ := db.RoomRole(database, roomID, userID)
	return role // "owner" | "admin" | ""
}

// KickMember removes a member from a public room (they may rejoin unless banned).
func KickMember(database *sql.DB, kick func(roomID, userID string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		callerID, _ := r.Context().Value(ContextUserID).(string)
		roomID := r.PathValue("room_id")
		var req struct {
			UserID string `json:"user_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.UserID == "" {
			writeError(w, http.StatusBadRequest, "invalid_request", "user_id required")
			return
		}
		if !canModerate(database, roomID, callerID, req.UserID) {
			writeError(w, http.StatusForbidden, "forbidden", "Not allowed")
			return
		}
		_ = db.RemoveRoomMember(database, roomID, req.UserID)
		kick(roomID, req.UserID)
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

// BanMember bans a member (durationSecs 0 = permanent) and removes them.
func BanMember(database *sql.DB, kick func(roomID, userID string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		callerID, _ := r.Context().Value(ContextUserID).(string)
		roomID := r.PathValue("room_id")
		var req struct {
			UserID       string `json:"user_id"`
			DurationSecs int64  `json:"duration_secs"` // 0 = permanent
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.UserID == "" {
			writeError(w, http.StatusBadRequest, "invalid_request", "user_id required")
			return
		}
		if !canModerate(database, roomID, callerID, req.UserID) {
			writeError(w, http.StatusForbidden, "forbidden", "Not allowed")
			return
		}
		var until int64
		if req.DurationSecs > 0 {
			until = time.Now().Unix() + req.DurationSecs
		}
		if err := db.BanRoomUser(database, roomID, req.UserID, until); err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Could not ban")
			return
		}
		kick(roomID, req.UserID)
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

// UnbanMember lifts a ban.
func UnbanMember(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		callerID, _ := r.Context().Value(ContextUserID).(string)
		roomID := r.PathValue("room_id")
		var req struct {
			UserID string `json:"user_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.UserID == "" {
			writeError(w, http.StatusBadRequest, "invalid_request", "user_id required")
			return
		}
		if requireAdmin(database, roomID, callerID) == "" {
			writeError(w, http.StatusForbidden, "forbidden", "Not an admin")
			return
		}
		_ = db.UnbanRoomUser(database, roomID, req.UserID)
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

// SetRoomAdmin promotes or demotes a member. Admins can promote members;
// only the owner can demote an admin.
func SetRoomAdmin(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		callerID, _ := r.Context().Value(ContextUserID).(string)
		roomID := r.PathValue("room_id")
		var req struct {
			UserID string `json:"user_id"`
			Grant  bool   `json:"grant"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.UserID == "" {
			writeError(w, http.StatusBadRequest, "invalid_request", "user_id required")
			return
		}
		callerRole := requireAdmin(database, roomID, callerID)
		if callerRole == "" {
			writeError(w, http.StatusForbidden, "forbidden", "Not an admin")
			return
		}
		if req.Grant {
			// Admins and the owner can promote a member to admin.
			if isMember, _ := db.IsRoomMember(database, roomID, req.UserID); !isMember {
				writeError(w, http.StatusBadRequest, "not_member", "User is not a member")
				return
			}
			_ = db.SetRoomAdmin(database, roomID, req.UserID, "admin")
		} else {
			// Only the owner can demote an admin.
			if callerRole != "owner" {
				writeError(w, http.StatusForbidden, "owner_only", "Only the owner can demote admins")
				return
			}
			_ = db.RemoveRoomAdmin(database, roomID, req.UserID)
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

// canModerate reports whether caller may kick/ban target: caller must be an
// admin/owner, cannot act on the owner, and only the owner may act on an admin.
func canModerate(database *sql.DB, roomID, callerID, targetID string) bool {
	if callerID == targetID {
		return false
	}
	callerRole := requireAdmin(database, roomID, callerID)
	if callerRole == "" {
		return false
	}
	targetRole, _ := db.RoomRole(database, roomID, targetID)
	if targetRole == "owner" {
		return false
	}
	if targetRole == "admin" && callerRole != "owner" {
		return false
	}
	return true
}
