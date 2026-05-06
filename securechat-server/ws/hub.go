package ws

import "sync"

// Hub manages all active WebSocket connections and room subscriptions.
type Hub struct {
	mu      sync.RWMutex
	clients map[string]*Client            // user_id → client
	rooms   map[string]map[string]*Client // room_id → user_id → client
}

func NewHub() *Hub {
	return &Hub{
		clients: make(map[string]*Client),
		rooms:   make(map[string]map[string]*Client),
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
