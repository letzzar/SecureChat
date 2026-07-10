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
	"github.com/securechat/server/ws"
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

// RoomMembers lists a public room's members with their roles. For a room hosted
// on a federated peer, it proxies the query to that peer.
func RoomMembers(database *sql.DB, hub *ws.Hub, fedClient *federation.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID, _ := r.Context().Value(ContextUserID).(string)
		roomID := r.PathValue("room_id")

		if home := hub.RemoteRoomHome(roomID); home != "" {
			peer := peerByURL(database, home)
			if peer == nil || fedClient == nil {
				writeError(w, http.StatusBadGateway, "no_home", "Room host unreachable")
				return
			}
			members, err := fedClient.RoomMembersRemote(peer, roomID)
			if err != nil {
				writeError(w, http.StatusBadGateway, "home_error", "Could not fetch members")
				return
			}
			writeJSON(w, http.StatusOK, members)
			return
		}

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

func peerByURL(database *sql.DB, url string) *db.FederationPeer {
	peers, _ := db.GetFederationPeers(database)
	for _, p := range peers {
		if p.URL == url {
			return p
		}
	}
	return nil
}

// disconnectFromRoom kicks a user from local subscribers and tells subscribed
// federated peers to do the same.
func disconnectFromRoom(database *sql.DB, hub *ws.Hub, fedClient *federation.Client, roomID, userID string) {
	hub.KickFromRoom(roomID, userID)
	if fedClient == nil {
		return
	}
	peerURLs := hub.RoomPeers(roomID)
	if len(peerURLs) == 0 {
		return
	}
	peers, _ := db.GetFederationPeers(database)
	byURL := make(map[string]*db.FederationPeer, len(peers))
	for _, p := range peers {
		byURL[p.URL] = p
	}
	for _, u := range peerURLs {
		if p := byURL[u]; p != nil {
			go fedClient.NotifyKicked(p, roomID, userID)
		}
	}
}

// applyModeration performs a moderation action on a room hosted by THIS server.
// Returns an HTTP status and an error code ("" on success).
func applyModeration(database *sql.DB, hub *ws.Hub, fedClient *federation.Client, roomID, actor, action, target string, duration int64) (int, string) {
	switch action {
	case "kick":
		if !canModerate(database, roomID, actor, target) {
			return http.StatusForbidden, "forbidden"
		}
		_ = db.RemoveRoomMember(database, roomID, target)
		disconnectFromRoom(database, hub, fedClient, roomID, target)
	case "ban":
		if !canModerate(database, roomID, actor, target) {
			return http.StatusForbidden, "forbidden"
		}
		var until int64
		if duration > 0 {
			until = time.Now().Unix() + duration
		}
		if err := db.BanRoomUser(database, roomID, target, until); err != nil {
			return http.StatusInternalServerError, "db_error"
		}
		disconnectFromRoom(database, hub, fedClient, roomID, target)
	case "unban":
		if requireAdmin(database, roomID, actor) == "" {
			return http.StatusForbidden, "forbidden"
		}
		_ = db.UnbanRoomUser(database, roomID, target)
	case "promote":
		if requireAdmin(database, roomID, actor) == "" {
			return http.StatusForbidden, "forbidden"
		}
		if m, _ := db.IsRoomMember(database, roomID, target); !m {
			return http.StatusBadRequest, "not_member"
		}
		_ = db.SetRoomAdmin(database, roomID, target, "admin")
	case "demote":
		if requireAdmin(database, roomID, actor) != "owner" {
			return http.StatusForbidden, "owner_only"
		}
		_ = db.RemoveRoomAdmin(database, roomID, target)
	default:
		return http.StatusBadRequest, "bad_action"
	}
	return http.StatusOK, ""
}

// clientModerate handles a client moderation request: proxy to the room's home
// if remote, else apply locally.
func clientModerate(w http.ResponseWriter, r *http.Request, database *sql.DB, hub *ws.Hub, fedClient *federation.Client, action, target string, duration int64) {
	callerID, _ := r.Context().Value(ContextUserID).(string)
	roomID := r.PathValue("room_id")
	if target == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "user_id required")
		return
	}
	if home := hub.RemoteRoomHome(roomID); home != "" {
		peer := peerByURL(database, home)
		if peer == nil || fedClient == nil {
			writeError(w, http.StatusBadGateway, "no_home", "Room host unreachable")
			return
		}
		if err := fedClient.RoomModerate(peer, roomID, callerID, action, target, duration); err != nil {
			writeError(w, http.StatusForbidden, "forbidden", "Not allowed or host error")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
		return
	}
	if status, code := applyModeration(database, hub, fedClient, roomID, callerID, action, target, duration); status != http.StatusOK {
		writeError(w, status, code, code)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// KickMember removes a member from a public room (they may rejoin unless banned).
func KickMember(database *sql.DB, hub *ws.Hub, fedClient *federation.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			UserID string `json:"user_id"`
		}
		json.NewDecoder(r.Body).Decode(&req)
		clientModerate(w, r, database, hub, fedClient, "kick", req.UserID, 0)
	}
}

// BanMember bans a member (duration_secs 0 = permanent) and removes them.
func BanMember(database *sql.DB, hub *ws.Hub, fedClient *federation.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			UserID       string `json:"user_id"`
			DurationSecs int64  `json:"duration_secs"`
		}
		json.NewDecoder(r.Body).Decode(&req)
		clientModerate(w, r, database, hub, fedClient, "ban", req.UserID, req.DurationSecs)
	}
}

// UnbanMember lifts a ban.
func UnbanMember(database *sql.DB, hub *ws.Hub, fedClient *federation.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			UserID string `json:"user_id"`
		}
		json.NewDecoder(r.Body).Decode(&req)
		clientModerate(w, r, database, hub, fedClient, "unban", req.UserID, 0)
	}
}

// SetRoomAdmin promotes or demotes a member.
func SetRoomAdmin(database *sql.DB, hub *ws.Hub, fedClient *federation.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			UserID string `json:"user_id"`
			Grant  bool   `json:"grant"`
		}
		json.NewDecoder(r.Body).Decode(&req)
		action := "demote"
		if req.Grant {
			action = "promote"
		}
		clientModerate(w, r, database, hub, fedClient, action, req.UserID, 0)
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
