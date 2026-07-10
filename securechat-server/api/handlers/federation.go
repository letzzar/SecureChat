package handlers

import (
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

// ── Public federation info ────────────────────────────────────────────────────

type federationInfoResponse struct {
	Name      string       `json:"name"`
	PublicURL string       `json:"public_url"`
	Mode      string       `json:"mode"`
	Peers     []peerPublic `json:"peers"`
}

type peerPublic struct {
	URL  string `json:"url"`
	Name string `json:"name"`
}

// GetFederationInfo returns public info about this node and its known peers.
// Clients use this on connect to discover backup servers.
func GetFederationInfo(cfg *config.Config, database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		peers, _ := db.GetFederationPeers(database)

		pub := make([]peerPublic, 0, len(peers))
		for _, p := range peers {
			pub = append(pub, peerPublic{URL: p.URL, Name: p.Name})
		}

		writeJSON(w, http.StatusOK, federationInfoResponse{
			Name:      cfg.Federation.Name,
			PublicURL: cfg.Federation.PublicURL,
			Mode:      cfg.Server.Mode,
			Peers:     pub,
		})
	}
}

// ── Admin middleware ──────────────────────────────────────────────────────────

func FederationAdminMiddleware(cfg *config.Config, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if cfg.Federation.AdminToken == "" {
			writeError(w, http.StatusForbidden, "federation_disabled",
				"Federation admin is not configured on this server")
			return
		}
		if r.Header.Get("X-Admin-Token") != cfg.Federation.AdminToken {
			writeError(w, http.StatusUnauthorized, "invalid_admin_token", "Invalid admin token")
			return
		}
		next(w, r)
	}
}

// ── Admin: manage peers ───────────────────────────────────────────────────────

type addPeerRequest struct {
	URL    string `json:"url"`
	Name   string `json:"name"`
	Secret string `json:"secret"` // the remote peer's federation.secret
}

func AddFederationPeer(cfg *config.Config, database *sql.DB) http.HandlerFunc {
	return FederationAdminMiddleware(cfg, func(w http.ResponseWriter, r *http.Request) {
		var req addPeerRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.URL == "" {
			writeError(w, http.StatusBadRequest, "invalid_request", "url, name, secret required")
			return
		}
		if err := db.AddFederationPeer(database, req.URL, req.Name, req.Secret); err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Could not add peer")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
}

func ListFederationPeers(cfg *config.Config, database *sql.DB) http.HandlerFunc {
	return FederationAdminMiddleware(cfg, func(w http.ResponseWriter, r *http.Request) {
		peers, err := db.GetFederationPeers(database)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Could not list peers")
			return
		}
		type peerAdmin struct {
			ID       int64  `json:"id"`
			URL      string `json:"url"`
			Name     string `json:"name"`
			AddedAt  int64  `json:"added_at"`
			LastSeen *int64 `json:"last_seen"`
		}
		result := make([]peerAdmin, 0, len(peers))
		for _, p := range peers {
			result = append(result, peerAdmin{
				ID: p.ID, URL: p.URL, Name: p.Name,
				AddedAt: p.AddedAt, LastSeen: p.LastSeen,
			})
		}
		writeJSON(w, http.StatusOK, result)
	})
}

func RemoveFederationPeer(cfg *config.Config, database *sql.DB) http.HandlerFunc {
	return FederationAdminMiddleware(cfg, func(w http.ResponseWriter, r *http.Request) {
		peerURL := r.URL.Query().Get("url")
		if peerURL == "" {
			writeError(w, http.StatusBadRequest, "missing_url", "url query param required")
			return
		}
		if err := db.DeleteFederationPeer(database, peerURL); err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Could not remove peer")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
}

// ── S2S middleware ────────────────────────────────────────────────────────────

func S2SMiddleware(cfg *config.Config, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if cfg.Federation.Secret == "" || !cfg.IsMesh() {
			writeError(w, http.StatusForbidden, "federation_disabled",
				"This server does not participate in a federation mesh")
			return
		}
		if r.Header.Get("X-Federation-Secret") != cfg.Federation.Secret {
			writeError(w, http.StatusUnauthorized, "invalid_secret", "Invalid federation secret")
			return
		}
		next(w, r)
	}
}

// ── S2S: user lookup ──────────────────────────────────────────────────────────

func S2SGetUser(cfg *config.Config, database *sql.DB) http.HandlerFunc {
	return S2SMiddleware(cfg, func(w http.ResponseWriter, r *http.Request) {
		userID := r.PathValue("user_id")
		if userID == "" {
			writeError(w, http.StatusBadRequest, "missing_user_id", "user_id required")
			return
		}
		u, err := db.GetUser(database, userID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Database error")
			return
		}
		if u == nil {
			writeError(w, http.StatusNotFound, "not_found", "User not found")
			return
		}
		writeJSON(w, http.StatusOK, userResponse{
			UserID:      u.UserID,
			DisplayName: u.DisplayName,
			PublicKey:   hex.EncodeToString(u.PublicKey),
			SignPublic:  hex.EncodeToString(u.SignPublic),
		})
	})
}

func S2SSearchUsers(cfg *config.Config, database *sql.DB) http.HandlerFunc {
	return S2SMiddleware(cfg, func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query().Get("q")
		if q == "" {
			writeError(w, http.StatusBadRequest, "missing_q", "q required")
			return
		}
		users, err := db.SearchUsers(database, q, 10)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Database error")
			return
		}
		results := make([]userResponse, 0, len(users))
		for _, u := range users {
			results = append(results, userResponse{
				UserID:      u.UserID,
				DisplayName: u.DisplayName,
				PublicKey:   hex.EncodeToString(u.PublicKey),
				SignPublic:  hex.EncodeToString(u.SignPublic),
			})
		}
		writeJSON(w, http.StatusOK, results)
	})
}

// ── S2S: public rooms discovery ──────────────────────────────────────────────

// S2SSearchPublicRooms advertises this server's public rooms to federated
// peers. Private rooms are never listed here (privacy).
func S2SSearchPublicRooms(cfg *config.Config, database *sql.DB) http.HandlerFunc {
	return S2SMiddleware(cfg, func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query().Get("q")
		rooms, err := db.SearchPublicRooms(database, q, 50)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Database error")
			return
		}
		out := make([]publicRoomResponse, 0, len(rooms))
		for _, rm := range rooms {
			out = append(out, publicRoomResponse{
				RoomID: rm.RoomID, RoomName: rm.RoomName,
				MemberCount: rm.MemberCount, IsPublic: true,
			})
		}
		writeJSON(w, http.StatusOK, out)
	})
}

// ── S2S: room relay (Phase 2) ────────────────────────────────────────────────

type roomSubReq struct {
	RoomID  string `json:"room_id"`
	UserID  string `json:"user_id"`
	PeerURL string `json:"peer_url"`
}

// S2SRoomSubscribe registers that a peer has a subscriber for one of our rooms.
// For public rooms it enforces bans and records membership.
func S2SRoomSubscribe(cfg *config.Config, database *sql.DB, hub *ws.Hub) http.HandlerFunc {
	return S2SMiddleware(cfg, func(w http.ResponseWriter, r *http.Request) {
		var req roomSubReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.RoomID == "" || req.PeerURL == "" {
			writeError(w, http.StatusBadRequest, "invalid_request", "room_id and peer_url required")
			return
		}
		room, _ := db.GetRoom(database, req.RoomID)
		if room == nil {
			writeError(w, http.StatusNotFound, "not_found", "Room not found")
			return
		}
		if req.UserID != "" {
			if banned, _ := db.IsRoomBanned(database, req.RoomID, req.UserID); banned {
				writeError(w, http.StatusForbidden, "banned", "User is banned")
				return
			}
			if room.IsPublic {
				_ = db.AddRoomMember(database, req.RoomID, req.UserID)
			}
		}
		hub.AddRoomPeer(req.RoomID, req.PeerURL)
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
}

// S2SRoomUnsubscribe drops a peer's subscription for one of our rooms.
func S2SRoomUnsubscribe(cfg *config.Config, database *sql.DB, hub *ws.Hub) http.HandlerFunc {
	return S2SMiddleware(cfg, func(w http.ResponseWriter, r *http.Request) {
		var req roomSubReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.RoomID == "" {
			writeError(w, http.StatusBadRequest, "invalid_request", "room_id required")
			return
		}
		if req.PeerURL != "" {
			hub.RemoveRoomPeer(req.RoomID, req.PeerURL)
		}
		if req.UserID != "" {
			if room, _ := db.GetRoom(database, req.RoomID); room != nil && room.IsPublic {
				_ = db.RemoveRoomMember(database, req.RoomID, req.UserID)
			}
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
}

// S2SRoomMessage delivers a room message from a peer to our local subscribers.
// If we host the room, we also fan it out to the other subscribed peers.
func S2SRoomMessage(cfg *config.Config, database *sql.DB, hub *ws.Hub, fedClient *federation.Client) http.HandlerFunc {
	return S2SMiddleware(cfg, func(w http.ResponseWriter, r *http.Request) {
		var m federation.RoomRelayMsg
		if err := json.NewDecoder(r.Body).Decode(&m); err != nil || m.RoomID == "" {
			writeError(w, http.StatusBadRequest, "invalid_request", "room_id required")
			return
		}

		out := &ws.OutgoingMessage{
			Type:    "room_msg",
			From:    m.From,
			RoomID:  m.RoomID,
			Nonce:   m.Nonce,
			Payload: m.Payload,
			Ts:      m.Ts,
		}
		// Deliver to local subscribers (except the original sender — echo).
		hub.BroadcastRoomByUser(m.RoomID, m.From, out)

		// If we are the room's home, fan out to the other subscribed peers.
		if exists, _ := db.RoomExists(database, m.RoomID); exists {
			subPeers := hub.RoomPeers(m.RoomID)
			if len(subPeers) > 0 && fedClient != nil {
				peers, _ := db.GetFederationPeers(database)
				byURL := make(map[string]*db.FederationPeer, len(peers))
				for _, p := range peers {
					byURL[p.URL] = p
				}
				for _, purl := range subPeers {
					if purl == m.Origin {
						continue
					}
					p := byURL[purl]
					if p == nil {
						continue
					}
					relay := &federation.RoomRelayMsg{
						RoomID: m.RoomID, From: m.From, Nonce: m.Nonce,
						Payload: m.Payload, Ts: m.Ts, Origin: cfg.Federation.PublicURL,
					}
					go fedClient.RelayRoomMessage(p, relay)
				}
			}
		}
		w.WriteHeader(http.StatusAccepted)
	})
}

// ── S2S: message relay ────────────────────────────────────────────────────────

// S2SRelayMessage accepts an encrypted DM from a peer and delivers it locally.
func S2SRelayMessage(cfg *config.Config, database *sql.DB, hub *ws.Hub) http.HandlerFunc {
	return S2SMiddleware(cfg, func(w http.ResponseWriter, r *http.Request) {
		var msg struct {
			Type    string `json:"type"`
			From    string `json:"from"`
			To      string `json:"to"`
			Nonce   string `json:"nonce"`
			Payload string `json:"payload"`
			Sig     string `json:"sig"`
			Seq     int64  `json:"seq"`
			Ts      int64  `json:"ts"`
			EPub    string `json:"e_pub"`
		}
		if err := json.NewDecoder(r.Body).Decode(&msg); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_json", "Invalid JSON")
			return
		}
		if msg.To == "" || msg.Payload == "" {
			writeError(w, http.StatusBadRequest, "missing_fields", "to and payload required")
			return
		}

		out := &ws.OutgoingMessage{
			Type:    msg.Type,
			From:    msg.From,
			To:      msg.To,
			Nonce:   msg.Nonce,
			Payload: msg.Payload,
			Sig:     msg.Sig,
			Seq:     msg.Seq,
			Ts:      msg.Ts,
			EPub:    msg.EPub,
		}

		delivered := hub.Send(msg.To, out)
		if !delivered {
			// Recipient is offline — queue for later delivery
			now := time.Now().Unix()
			_ = db.SaveOfflineMessage(database, &db.OfflineMsg{
				RecipientID: msg.To,
				MsgType:     msg.Type,
				FromID:      msg.From,
				Payload:     msg.Payload,
				Nonce:       msg.Nonce,
				Sig:         msg.Sig,
				Seq:         msg.Seq,
				EPub:        msg.EPub,
				CreatedAt:   now,
				ExpiresAt:   now + int64(cfg.Limits.OfflineTTLHours)*3600,
			})
		}

		w.WriteHeader(http.StatusAccepted)
	})
}
