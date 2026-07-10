package ws

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/gorilla/websocket"
	jwtauth "github.com/securechat/server/auth"
	"github.com/securechat/server/config"
	"github.com/securechat/server/crypto"
	"github.com/securechat/server/db"
	"github.com/securechat/server/federation"
	"github.com/securechat/server/sfu"
)

const (
	writeWait            = 10 * time.Second
	pongWait             = 60 * time.Second
	pingPeriod           = 50 * time.Second
	maxMessageSize       = 65536
	sendBufSize          = 64
	maxMessagesPerMinute = 100 // design §13: rate limit per connection
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	// Accept native clients (no Origin header) and same-origin web clients only.
	CheckOrigin: func(r *http.Request) bool {
		origin := r.Header.Get("Origin")
		if origin == "" {
			return true
		}
		u, err := url.Parse(origin)
		if err != nil {
			return false
		}
		return u.Host == r.Host
	},
}

// Client represents a single WebSocket connection.
type Client struct {
	userID     string
	signPublic []byte // sender's Ed25519 public key, cached at connect time
	conn       *websocket.Conn
	send       chan *OutgoingMessage
	hub        *Hub
	database   *sql.DB
	cfg        *config.Config
	sfu        *sfu.SFU
	fed        *federation.Client // nil when not in mesh mode

	// Per-connection rate limiting (accessed only from readPump goroutine).
	msgWindowStart time.Time
	msgCount       int
}

// ServeWS upgrades the HTTP connection and starts the client pump goroutines.
func ServeWS(hub *Hub, database *sql.DB, cfg *config.Config, sfuInst *sfu.SFU, fedClient *federation.Client, w http.ResponseWriter, r *http.Request) {
	// Authenticate via JWT query param
	tokenStr := r.URL.Query().Get("token")
	if tokenStr == "" {
		http.Error(w, "missing token", http.StatusUnauthorized)
		return
	}

	userID, err := jwtauth.ValidateJWT(cfg, tokenStr)
	if err != nil {
		http.Error(w, "invalid token", http.StatusUnauthorized)
		return
	}

	// Load the sender's registered Ed25519 public key so DM signatures can be
	// verified without a DB hit per message. Fails closed if the user is gone.
	sender, err := db.GetUser(database, userID)
	if err != nil || sender == nil {
		http.Error(w, "unknown user", http.StatusUnauthorized)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("ws upgrade: %v", err)
		return
	}

	c := &Client{
		userID:     userID,
		signPublic: sender.SignPublic,
		conn:       conn,
		send:       make(chan *OutgoingMessage, sendBufSize),
		hub:        hub,
		database:   database,
		cfg:        cfg,
		sfu:        sfuInst,
		fed:        fedClient,
	}

	hub.Register(c)
	db.UpdateLastSeen(database, userID)

	go c.writePump()
	go c.readPump()

	// Deliver any queued offline messages
	go c.deliverOffline()
}

func (c *Client) readPump() {
	defer func() {
		c.hub.Unregister(c)
		c.conn.Close()
	}()

	c.conn.SetReadLimit(maxMessageSize)
	c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	for {
		_, raw, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err,
				websocket.CloseGoingAway,
				websocket.CloseNormalClosure,
				websocket.CloseAbnormalClosure) {
				log.Printf("ws read error [%s]: %v", c.userID, err)
			}
			break
		}
		c.handleMessage(raw)
	}
}

func (c *Client) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()

	for {
		select {
		case msg, ok := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := c.conn.WriteJSON(msg); err != nil {
				log.Printf("ws write error [%s]: %v", c.userID, err)
				return
			}

		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func (c *Client) handleMessage(raw []byte) {
	if !c.allowMessage() {
		c.sendError("rate_limited", "Too many messages; slow down")
		return
	}

	var msg IncomingMessage
	if err := json.Unmarshal(raw, &msg); err != nil {
		c.sendError("invalid_json", "Invalid JSON")
		return
	}

	switch msg.Type {
	case "ping":
		c.send <- &OutgoingMessage{Type: "pong"}

	case "dm", "noise_init", "noise_resp":
		c.handleDM(&msg)

	case "room_join":
		c.handleRoomJoin(&msg)

	case "room_leave":
		c.handleRoomLeave(&msg)

	case "room_msg":
		c.handleRoomMsg(&msg)

	case "voice_join":
		c.handleVoiceJoin(&msg)
	case "voice_leave":
		c.handleVoiceLeave(&msg)
	case "sdp_offer":
		c.handleSdpOffer(&msg)
	case "sdp_answer":
		c.handleSdpAnswer(&msg)
	case "ice_candidate":
		c.handleIceCandidate(&msg)

	case "file_offer":
		c.handleFileOffer(&msg)
	case "file_chunk":
		c.handleFileChunk(&msg)
	case "file_accept", "file_reject", "file_cancel", "file_done":
		c.handleFileRelay(&msg)

	case "dm_call_offer", "dm_call_answer", "dm_call_reject", "dm_call_end", "dm_ice_candidate":
		c.handleDmCallSignal(&msg)

	default:
		c.sendError("unknown_type", "Unknown message type: "+msg.Type)
	}
}

func (c *Client) handleDM(msg *IncomingMessage) {
	if msg.To == "" || msg.Payload == "" {
		c.sendError("invalid_dm", "DM requires 'to' and 'payload'")
		return
	}
	if msg.Sig == "" {
		c.sendError("missing_sig", "DM requires Ed25519 signature")
		return
	}

	// Verify the sender actually signed this message with their registered
	// Ed25519 key. The signed content must match exactly what the client signs
	// (see app messages_store.dart): "<type>:<to>:<nonce>:<payload>" for the
	// handshake, with ":<seq>" appended for a plain dm.
	signed := msg.Type + ":" + msg.To + ":" + msg.Nonce + ":" + msg.Payload
	if msg.Type == "dm" {
		signed += ":" + strconv.FormatInt(msg.Seq, 10)
	}
	if !crypto.VerifySignature(c.signPublic, []byte(signed), msg.Sig) {
		c.sendError("invalid_sig", "Ed25519 signature verification failed")
		return
	}

	out := &OutgoingMessage{
		Type:    msg.Type,
		From:    c.userID,
		To:      msg.To,
		Nonce:   msg.Nonce,
		Payload: msg.Payload,
		Sig:     msg.Sig,
		Seq:     msg.Seq,
		Ts:      msg.Ts,
		EPub:    msg.EPub,
	}

	delivered := c.hub.Send(msg.To, out)

	if !delivered {
		localUser, _ := db.GetUser(c.database, msg.To)
		if localUser != nil {
			// Recipient is a local user but currently offline — queue.
			now := time.Now().Unix()
			_ = db.SaveOfflineMessage(c.database, &db.OfflineMsg{
				RecipientID: msg.To,
				MsgType:     msg.Type,
				FromID:      c.userID,
				Payload:     msg.Payload,
				Nonce:       msg.Nonce,
				Sig:         msg.Sig,
				Seq:         msg.Seq,
				EPub:        msg.EPub,
				CreatedAt:   now,
				ExpiresAt:   now + int64(c.cfg.Limits.OfflineTTLHours)*3600,
			})
		} else if c.cfg.IsMesh() && c.fed != nil {
			// Recipient is not local — try to relay to a federated peer.
			relay := &federation.RelayMsg{
				Type:    msg.Type,
				From:    c.userID,
				To:      msg.To,
				Nonce:   msg.Nonce,
				Payload: msg.Payload,
				Sig:     msg.Sig,
				Seq:     msg.Seq,
				Ts:      msg.Ts,
				EPub:    msg.EPub,
			}
			go func() {
				peers, err := db.GetFederationPeers(c.database)
				if err != nil || len(peers) == 0 {
					return
				}
				peer, _ := c.fed.LookupUser(peers, msg.To)
				if peer == nil {
					log.Printf("federation: no peer has user %s", msg.To)
					return
				}
				if err := c.fed.RelayMessage(peer, relay); err != nil {
					log.Printf("federation relay to %s: %v", peer.URL, err)
				} else {
					db.UpdateFederationPeerSeen(c.database, peer.URL)
				}
			}()
		}
	}

	// Ack to sender
	if msg.Seq > 0 {
		c.send <- &OutgoingMessage{Type: "delivered", DeliveredSeq: msg.Seq}
	}
}

func (c *Client) deliverOffline() {
	msgs, err := db.GetOfflineMessages(c.database, c.userID)
	if err != nil {
		log.Printf("offline delivery error [%s]: %v", c.userID, err)
		return
	}
	for _, m := range msgs {
		c.send <- &OutgoingMessage{
			Type:    m.MsgType,
			From:    m.FromID,
			To:      c.userID,
			Payload: m.Payload,
			Nonce:   m.Nonce,
			Sig:     m.Sig,
			Seq:     m.Seq,
			EPub:    m.EPub,
		}
	}
	if len(msgs) > 0 {
		_ = db.DeleteOfflineMessages(c.database, c.userID)
	}
}

func (c *Client) handleRoomJoin(msg *IncomingMessage) {
	if msg.RoomID == "" {
		c.sendError("invalid_room_join", "room_id required")
		return
	}

	// Remote room hosted on a federated peer (Phase 2).
	selfURL := c.cfg.Federation.PublicURL
	if msg.Home != "" && msg.Home != selfURL {
		peer := c.peerByURL(msg.Home)
		if peer == nil {
			c.sendError("unknown_home", "This server is not federated with the room's host")
			return
		}
		c.hub.SetRemoteRoom(msg.RoomID, msg.Home, msg.Private)
		c.hub.JoinRoom(msg.RoomID, c) // local subscription for fan-back delivery
		// For private rooms, do not reveal our identity to the host; the sender
		// travels inside the ciphertext. Public rooms track membership by user.
		subUser := c.userID
		if msg.Private {
			subUser = ""
		}
		go c.fed.SubscribeRoom(peer, msg.RoomID, subUser, selfURL)
		c.send <- &OutgoingMessage{Type: "room_joined", RoomID: msg.RoomID}
		return
	}

	exists, err := db.RoomExists(c.database, msg.RoomID)
	if err != nil || !exists {
		c.sendError("room_not_found", "Room does not exist")
		return
	}
	if banned, _ := db.IsRoomBanned(c.database, msg.RoomID, c.userID); banned {
		c.sendError("banned", "You are banned from this room")
		return
	}
	c.hub.JoinRoom(msg.RoomID, c)
	c.send <- &OutgoingMessage{Type: "room_joined", RoomID: msg.RoomID}
}

func (c *Client) handleRoomLeave(msg *IncomingMessage) {
	if msg.RoomID == "" {
		return
	}
	if home := c.hub.RemoteRoomHome(msg.RoomID); home != "" {
		if peer := c.peerByURL(home); peer != nil {
			subUser := c.userID
			if c.hub.IsRemoteRoomPrivate(msg.RoomID) {
				subUser = "" // stayed anonymous to the host; unsubscribe likewise
			}
			go c.fed.UnsubscribeRoom(peer, msg.RoomID, subUser, c.cfg.Federation.PublicURL)
		}
	}
	c.hub.LeaveRoom(msg.RoomID, c)
	c.send <- &OutgoingMessage{Type: "room_left", RoomID: msg.RoomID}
}

func (c *Client) handleRoomMsg(msg *IncomingMessage) {
	if msg.RoomID == "" || msg.Payload == "" || msg.Nonce == "" {
		c.sendError("invalid_room_msg", "room_id, nonce, payload required")
		return
	}

	// Remote room — relay to the home server; local subscribers get the message
	// when the home fans it back. Content stays opaque.
	if home := c.hub.RemoteRoomHome(msg.RoomID); home != "" {
		// Private room: sender lives inside the ciphertext, so the host only
		// ever sees room_id + opaque payload — never who is talking.
		from := c.userID
		if c.hub.IsRemoteRoomPrivate(msg.RoomID) {
			from = ""
		}
		// Deliver to our own local subscribers now (except the sender). We tag the
		// relay with our URL as Origin so the home does not fan it back to us,
		// which would duplicate the message on this server.
		selfURL := c.cfg.Federation.PublicURL
		c.hub.BroadcastRoom(msg.RoomID, c, &OutgoingMessage{
			Type: "room_msg", From: from, RoomID: msg.RoomID,
			Nonce: msg.Nonce, Payload: msg.Payload, Ts: msg.Ts,
		})
		if peer := c.peerByURL(home); peer != nil && c.fed != nil {
			go c.fed.RelayRoomMessage(peer, &federation.RoomRelayMsg{
				RoomID: msg.RoomID, From: from, Nonce: msg.Nonce,
				Payload: msg.Payload, Ts: msg.Ts, Origin: selfURL,
			})
		}
		return
	}

	// Local room — must exist; content stays opaque.
	room, err := db.GetRoom(c.database, msg.RoomID)
	if err != nil || room == nil {
		c.sendError("room_not_found", "Room does not exist")
		return
	}
	if banned, _ := db.IsRoomBanned(c.database, msg.RoomID, c.userID); banned {
		c.sendError("banned", "You are banned from this room")
		return
	}

	out := &OutgoingMessage{
		Type:    "room_msg",
		From:    c.userID,
		RoomID:  msg.RoomID,
		Nonce:   msg.Nonce,
		Payload: msg.Payload,
		Ts:      msg.Ts,
	}
	c.hub.BroadcastRoom(msg.RoomID, c, out)
	// When fanning to federated peers, strip the sender for private rooms so no
	// remote server learns who is talking (sender is inside the ciphertext).
	fanFrom := c.userID
	if !room.IsPublic {
		fanFrom = ""
	}
	c.fanRoomToPeers(msg.RoomID, fanFrom, msg.Nonce, msg.Payload, msg.Ts)
}

// peerByURL finds a federated peer by URL.
func (c *Client) peerByURL(url string) *db.FederationPeer {
	peers, _ := db.GetFederationPeers(c.database)
	for _, p := range peers {
		if p.URL == url {
			return p
		}
	}
	return nil
}

// fanRoomToPeers (home side) relays a local room message to subscribed peers.
func (c *Client) fanRoomToPeers(roomID, from, nonce, payload string, ts int64) {
	if c.fed == nil {
		return
	}
	peerURLs := c.hub.RoomPeers(roomID)
	if len(peerURLs) == 0 {
		return
	}
	peers, _ := db.GetFederationPeers(c.database)
	byURL := make(map[string]*db.FederationPeer, len(peers))
	for _, p := range peers {
		byURL[p.URL] = p
	}
	for _, u := range peerURLs {
		if p := byURL[u]; p != nil {
			go c.fed.RelayRoomMessage(p, &federation.RoomRelayMsg{
				RoomID: roomID, From: from, Nonce: nonce, Payload: payload, Ts: ts,
				Origin: c.cfg.Federation.PublicURL,
			})
		}
	}
}

func (c *Client) handleVoiceJoin(msg *IncomingMessage) {
	if msg.RoomID == "" {
		c.sendError("invalid_voice_join", "room_id required")
		return
	}

	// Require the room to exist before creating an SFU peer, so the SFU never
	// spins up rooms for arbitrary ids. NOTE: the server cannot verify knowledge
	// of the room password (it never sees room_key); password-gating remains a
	// client-side + room_id-secrecy guarantee (design §8).
	exists, err := db.RoomExists(c.database, msg.RoomID)
	if err != nil || !exists {
		c.sendError("room_not_found", "Room does not exist")
		return
	}

	sendFn := func(msgType, payload, roomID string) {
		out := &OutgoingMessage{Type: msgType, RoomID: roomID}
		switch msgType {
		case "sdp_offer", "sdp_answer":
			out.SDP = payload
		case "ice_candidate":
			out.Candidate = payload
		}
		select {
		case c.send <- out:
		default:
		}
	}

	if err := c.sfu.Join(msg.RoomID, c.userID, sendFn); err != nil {
		c.sendError("voice_join_failed", err.Error())
		return
	}

	// Join the WS room so voice events are broadcast correctly
	c.hub.JoinRoom(msg.RoomID, c)

	participants := c.sfu.Participants(msg.RoomID)
	c.send <- &OutgoingMessage{
		Type:              "voice_joined",
		RoomID:            msg.RoomID,
		VoiceParticipants: participants,
	}

	c.hub.BroadcastRoom(msg.RoomID, c, &OutgoingMessage{
		Type:   "voice_user_joined",
		From:   c.userID,
		RoomID: msg.RoomID,
	})
}

func (c *Client) handleVoiceLeave(msg *IncomingMessage) {
	if msg.RoomID == "" {
		return
	}
	c.sfu.Leave(msg.RoomID, c.userID)
	c.send <- &OutgoingMessage{Type: "voice_left", RoomID: msg.RoomID}
}

func (c *Client) handleSdpOffer(msg *IncomingMessage) {
	if msg.RoomID == "" || msg.SDP == "" {
		c.sendError("invalid_sdp_offer", "room_id and sdp required")
		return
	}
	answer, err := c.sfu.HandleOffer(msg.RoomID, c.userID, msg.SDP)
	if err != nil {
		log.Printf("sdp offer [%s]: %v", c.userID, err)
		c.sendError("sdp_error", "Could not process offer")
		return
	}
	c.send <- &OutgoingMessage{Type: "sdp_answer", RoomID: msg.RoomID, SDP: answer}
}

func (c *Client) handleSdpAnswer(msg *IncomingMessage) {
	if msg.RoomID == "" || msg.SDP == "" {
		return
	}
	if err := c.sfu.HandleAnswer(msg.RoomID, c.userID, msg.SDP); err != nil {
		log.Printf("sdp answer [%s]: %v", c.userID, err)
	}
}

func (c *Client) handleIceCandidate(msg *IncomingMessage) {
	if msg.RoomID == "" || msg.Candidate == "" {
		return
	}
	if err := c.sfu.HandleICECandidate(msg.RoomID, c.userID, msg.Candidate); err != nil {
		log.Printf("ice candidate [%s]: %v", c.userID, err)
	}
}

// handleFileOffer relays a file transfer offer only if the recipient is currently online.
// Metadata (file name, size, mime) is E2E-encrypted by the client inside payload.
func (c *Client) handleFileOffer(msg *IncomingMessage) {
	if msg.To == "" || msg.FileID == "" || msg.Payload == "" {
		c.sendError("invalid_file_offer", "file_offer requires to, file_id, payload")
		return
	}
	if !c.hub.IsOnline(msg.To) {
		c.send <- &OutgoingMessage{
			Type:   "file_error",
			FileID: msg.FileID,
			Code:   "user_offline",
			Msg:    "Recipient is not online",
		}
		return
	}
	c.hub.Send(msg.To, &OutgoingMessage{
		Type:    "file_offer",
		From:    c.userID,
		FileID:  msg.FileID,
		Payload: msg.Payload,
		Nonce:   msg.Nonce,
		Sig:     msg.Sig,
		EPub:    msg.EPub,
	})
}

// handleFileChunk relays an encrypted file chunk. If the recipient has gone offline
// mid-transfer, sends file_cancel back to the sender so it can abort.
func (c *Client) handleFileChunk(msg *IncomingMessage) {
	if msg.To == "" || msg.FileID == "" || msg.Payload == "" {
		c.sendError("invalid_file_chunk", "file_chunk requires to, file_id, payload")
		return
	}
	delivered := c.hub.Send(msg.To, &OutgoingMessage{
		Type:       "file_chunk",
		From:       c.userID,
		FileID:     msg.FileID,
		ChunkIndex: msg.ChunkIndex,
		ChunkTotal: msg.ChunkTotal,
		Payload:    msg.Payload,
		Nonce:      msg.Nonce,
	})
	if !delivered {
		c.send <- &OutgoingMessage{
			Type:   "file_cancel",
			FileID: msg.FileID,
			Code:   "user_offline",
			Msg:    "Recipient disconnected during transfer",
		}
	}
}

// handleFileRelay is a pure relay for accept / reject / cancel / done signals.
func (c *Client) handleFileRelay(msg *IncomingMessage) {
	if msg.To == "" || msg.FileID == "" {
		return
	}
	c.hub.Send(msg.To, &OutgoingMessage{
		Type:   msg.Type,
		From:   c.userID,
		FileID: msg.FileID,
	})
}

// handleDmCallSignal relays DM voice call signals (offer/answer/reject/end/ice) between two users.
func (c *Client) handleDmCallSignal(msg *IncomingMessage) {
	if msg.To == "" {
		return
	}
	c.hub.Send(msg.To, &OutgoingMessage{
		Type:      msg.Type,
		From:      c.userID,
		SDP:       msg.SDP,
		Candidate: msg.Candidate,
	})
}

// allowMessage enforces a fixed-window rate limit of maxMessagesPerMinute
// inbound messages per connection. Called only from the readPump goroutine.
func (c *Client) allowMessage() bool {
	now := time.Now()
	if now.Sub(c.msgWindowStart) >= time.Minute {
		c.msgWindowStart = now
		c.msgCount = 0
	}
	c.msgCount++
	return c.msgCount <= maxMessagesPerMinute
}

func (c *Client) sendError(code, msg string) {
	c.send <- &OutgoingMessage{Type: "error", Code: code, Msg: msg}
}
