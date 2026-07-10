package ws

import "sync"

// Hub manages all active WebSocket connections and room subscriptions.
type Hub struct {
	mu      sync.RWMutex
	clients map[string]*Client            // user_id → client
	rooms   map[string]map[string]*Client // room_id → user_id → client

	// Federation (Phase 2):
	// remoteRooms: rooms hosted on a peer that local clients subscribe to.
	remoteRooms map[string]string // room_id → home server URL
	// remotePrivate: which of those remote rooms are private (E2E). For these
	// the sender identity travels inside the ciphertext, so the outer `from`
	// is stripped before relaying to the home (it never learns who is talking).
	remotePrivate map[string]bool // room_id → private?
	// roomPeers: on the HOME server, peers that currently have subscribers.
	roomPeers map[string]map[string]bool // room_id → set(peer URL)
}

func NewHub() *Hub {
	return &Hub{
		clients:       make(map[string]*Client),
		rooms:         make(map[string]map[string]*Client),
		remoteRooms:   make(map[string]string),
		remotePrivate: make(map[string]bool),
		roomPeers:     make(map[string]map[string]bool),
	}
}

// SetRemoteRoom records that roomID is hosted on homeURL (a federated peer).
// private marks E2E rooms whose sender identity must stay inside the ciphertext.
func (h *Hub) SetRemoteRoom(roomID, homeURL string, private bool) {
	h.mu.Lock()
	h.remoteRooms[roomID] = homeURL
	h.remotePrivate[roomID] = private
	h.mu.Unlock()
}

// IsRemoteRoomPrivate reports whether a remote room is private (E2E).
func (h *Hub) IsRemoteRoomPrivate(roomID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.remotePrivate[roomID]
}

// RemoteRoomHome returns the home URL if roomID is a remote room, else "".
func (h *Hub) RemoteRoomHome(roomID string) string {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.remoteRooms[roomID]
}

// AddRoomPeer (home side) records that peerURL has subscribers for roomID.
func (h *Hub) AddRoomPeer(roomID, peerURL string) {
	h.mu.Lock()
	if h.roomPeers[roomID] == nil {
		h.roomPeers[roomID] = make(map[string]bool)
	}
	h.roomPeers[roomID][peerURL] = true
	h.mu.Unlock()
}

// RemoveRoomPeer (home side) drops a peer's subscription for roomID.
func (h *Hub) RemoveRoomPeer(roomID, peerURL string) {
	h.mu.Lock()
	if peers, ok := h.roomPeers[roomID]; ok {
		delete(peers, peerURL)
		if len(peers) == 0 {
			delete(h.roomPeers, roomID)
		}
	}
	h.mu.Unlock()
}

// RoomPeers returns the peer URLs subscribed to roomID (home side).
func (h *Hub) RoomPeers(roomID string) []string {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make([]string, 0, len(h.roomPeers[roomID]))
	for url := range h.roomPeers[roomID] {
		out = append(out, url)
	}
	return out
}

// BroadcastRoomByUser delivers msg to local room subscribers except the user
// exceptUserID (echo suppression when the sender lives on another server).
func (h *Hub) BroadcastRoomByUser(roomID, exceptUserID string, msg *OutgoingMessage) {
	h.mu.RLock()
	members := make([]*Client, 0, len(h.rooms[roomID]))
	for uid, c := range h.rooms[roomID] {
		if uid != exceptUserID {
			members = append(members, c)
		}
	}
	h.mu.RUnlock()
	for _, c := range members {
		select {
		case c.send <- msg:
		default:
		}
	}
}

func (h *Hub) Register(c *Client) {
	h.mu.Lock()
	h.clients[c.userID] = c
	h.mu.Unlock()
}

func (h *Hub) Unregister(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if existing, ok := h.clients[c.userID]; ok && existing == c {
		delete(h.clients, c.userID)
	}
	for roomID, members := range h.rooms {
		delete(members, c.userID)
		if len(members) == 0 {
			delete(h.rooms, roomID)
		}
	}
}

// Send delivers a DM to userID. Returns true if online.
func (h *Hub) Send(userID string, msg *OutgoingMessage) bool {
	h.mu.RLock()
	c, ok := h.clients[userID]
	h.mu.RUnlock()
	if !ok {
		return false
	}
	select {
	case c.send <- msg:
		return true
	default:
		return false
	}
}

// JoinRoom subscribes c to roomID.
func (h *Hub) JoinRoom(roomID string, c *Client) {
	h.mu.Lock()
	if h.rooms[roomID] == nil {
		h.rooms[roomID] = make(map[string]*Client)
	}
	h.rooms[roomID][c.userID] = c
	h.mu.Unlock()
}

// LeaveRoom unsubscribes c from roomID.
func (h *Hub) LeaveRoom(roomID string, c *Client) {
	h.mu.Lock()
	if members, ok := h.rooms[roomID]; ok {
		delete(members, c.userID)
		if len(members) == 0 {
			delete(h.rooms, roomID)
		}
	}
	h.mu.Unlock()
}

// BroadcastRoom sends msg to all room members except sender.
func (h *Hub) BroadcastRoom(roomID string, sender *Client, msg *OutgoingMessage) {
	h.mu.RLock()
	members := h.rooms[roomID]
	h.mu.RUnlock()
	for _, c := range members {
		if c == sender {
			continue
		}
		select {
		case c.send <- msg:
		default:
		}
	}
}

// KickFromRoom removes userID from roomID's live subscribers and notifies them
// (used by admin kick/ban).
func (h *Hub) KickFromRoom(roomID, userID string) {
	h.mu.Lock()
	var c *Client
	if members, ok := h.rooms[roomID]; ok {
		c = members[userID]
		delete(members, userID)
		if len(members) == 0 {
			delete(h.rooms, roomID)
		}
	}
	h.mu.Unlock()
	if c != nil {
		select {
		case c.send <- &OutgoingMessage{Type: "room_kicked", RoomID: roomID}:
		default:
		}
	}
}

// RoomMemberCount returns active subscribers for a room.
func (h *Hub) RoomMemberCount(roomID string) int {
	h.mu.RLock()
	n := len(h.rooms[roomID])
	h.mu.RUnlock()
	return n
}

func (h *Hub) IsOnline(userID string) bool {
	h.mu.RLock()
	_, ok := h.clients[userID]
	h.mu.RUnlock()
	return ok
}
