// Package federation provides server-to-server (S2S) communication for federated meshes.
package federation

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"

	"github.com/securechat/server/db"
)

// FedUser is a user record returned by S2S user lookups and searches.
type FedUser struct {
	UserID      string `json:"user_id"`
	DisplayName string `json:"display_name"`
	PublicKey   string `json:"public_key"`
	SignPublic  string `json:"sign_public"`
	ServerURL   string `json:"server_url,omitempty"`
}

// FedRoom is a public room advertised by a federated peer.
type FedRoom struct {
	RoomID      string `json:"room_id"`
	RoomName    string `json:"room_name"`
	MemberCount int    `json:"member_count"`
	ServerURL   string `json:"server_url,omitempty"`
}

// RoomRelayMsg is a room message relayed between federated servers. Payload is
// opaque (E2E ciphertext for private rooms; plaintext for public rooms).
type RoomRelayMsg struct {
	RoomID  string `json:"room_id"`
	From    string `json:"from"`
	Nonce   string `json:"nonce,omitempty"`
	Payload string `json:"payload"`
	Ts      int64  `json:"ts,omitempty"`
	Origin  string `json:"origin,omitempty"` // relaying peer URL (echo suppression)
}

// RelayMsg is the envelope sent to a peer's /s2s/message endpoint.
type RelayMsg struct {
	Type    string `json:"type"`
	From    string `json:"from"`
	To      string `json:"to"`
	Nonce   string `json:"nonce,omitempty"`
	Payload string `json:"payload,omitempty"`
	Sig     string `json:"sig,omitempty"`
	Seq     int64  `json:"seq,omitempty"`
	Ts      int64  `json:"ts,omitempty"`
	EPub    string `json:"e_pub,omitempty"`
}

// Client performs outgoing S2S calls to peer servers.
type Client struct {
	http *http.Client
}

// New returns a Client with a 5-second timeout per call.
func New() *Client {
	return &Client{
		http: &http.Client{Timeout: 5 * time.Second},
	}
}

// SearchUsers fans out a search query to all peers concurrently and aggregates results.
func (c *Client) SearchUsers(peers []*db.FederationPeer, query string) []FedUser {
	ch := make(chan []FedUser, len(peers))
	for _, p := range peers {
		go func(peer *db.FederationPeer) {
			users, err := c.searchPeer(peer, query)
			if err != nil {
				ch <- nil
				return
			}
			ch <- users
		}(p)
	}

	var all []FedUser
	for range peers {
		if users := <-ch; len(users) > 0 {
			all = append(all, users...)
		}
	}
	return all
}

func (c *Client) searchPeer(peer *db.FederationPeer, query string) ([]FedUser, error) {
	req, err := http.NewRequest("GET",
		peer.URL+"/s2s/users?q="+url.QueryEscape(query), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Federation-Secret", peer.Secret)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("peer %s returned %d", peer.URL, resp.StatusCode)
	}

	var users []FedUser
	if err := json.NewDecoder(resp.Body).Decode(&users); err != nil {
		return nil, err
	}
	for i := range users {
		users[i].ServerURL = peer.URL
	}
	return users, nil
}

// SearchPublicRooms fans out a public-room search to all peers concurrently and
// aggregates results. Only public rooms are ever advertised — private rooms are
// never listed cross-server.
func (c *Client) SearchPublicRooms(peers []*db.FederationPeer, query string) []FedRoom {
	ch := make(chan []FedRoom, len(peers))
	for _, p := range peers {
		go func(peer *db.FederationPeer) {
			rooms, err := c.searchPeerRooms(peer, query)
			if err != nil {
				ch <- nil
				return
			}
			ch <- rooms
		}(p)
	}

	var all []FedRoom
	for range peers {
		if rooms := <-ch; len(rooms) > 0 {
			all = append(all, rooms...)
		}
	}
	return all
}

func (c *Client) searchPeerRooms(peer *db.FederationPeer, query string) ([]FedRoom, error) {
	req, err := http.NewRequest("GET",
		peer.URL+"/s2s/rooms/public?q="+url.QueryEscape(query), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Federation-Secret", peer.Secret)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("peer %s returned %d", peer.URL, resp.StatusCode)
	}

	var rooms []FedRoom
	if err := json.NewDecoder(resp.Body).Decode(&rooms); err != nil {
		return nil, err
	}
	for i := range rooms {
		rooms[i].ServerURL = peer.URL
	}
	return rooms, nil
}

// LookupUser queries each peer until it finds the user. Returns the hosting peer and the user.
func (c *Client) LookupUser(peers []*db.FederationPeer, userID string) (*db.FederationPeer, *FedUser) {
	for _, p := range peers {
		user, err := c.lookupPeer(p, userID)
		if err == nil && user != nil {
			return p, user
		}
	}
	return nil, nil
}

func (c *Client) lookupPeer(peer *db.FederationPeer, userID string) (*FedUser, error) {
	req, err := http.NewRequest("GET",
		peer.URL+"/s2s/users/"+url.PathEscape(userID), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Federation-Secret", peer.Secret)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, nil
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("peer %s returned %d", peer.URL, resp.StatusCode)
	}

	var user FedUser
	if err := json.NewDecoder(resp.Body).Decode(&user); err != nil {
		return nil, err
	}
	return &user, nil
}

// RelayMessage forwards an already-encrypted DM to the peer that hosts the recipient.
func (c *Client) RelayMessage(peer *db.FederationPeer, msg *RelayMsg) error {
	return c.postJSON(peer, "/s2s/message", msg)
}

// SubscribeRoom tells the home peer that this server has a subscriber for a room.
func (c *Client) SubscribeRoom(peer *db.FederationPeer, roomID, userID, myURL string) error {
	return c.postJSON(peer, "/s2s/room/subscribe",
		map[string]any{"room_id": roomID, "user_id": userID, "peer_url": myURL})
}

// UnsubscribeRoom drops this server's subscription for a room on the home peer.
func (c *Client) UnsubscribeRoom(peer *db.FederationPeer, roomID, userID, myURL string) error {
	return c.postJSON(peer, "/s2s/room/unsubscribe",
		map[string]any{"room_id": roomID, "user_id": userID, "peer_url": myURL})
}

// RelayRoomMessage forwards a room message to a peer.
func (c *Client) RelayRoomMessage(peer *db.FederationPeer, msg *RoomRelayMsg) error {
	return c.postJSON(peer, "/s2s/room/message", msg)
}

// RoomMembersRemote fetches the member list of a room hosted on [peer].
func (c *Client) RoomMembersRemote(peer *db.FederationPeer, roomID string) ([]map[string]any, error) {
	req, err := http.NewRequest("GET", peer.URL+"/s2s/room/"+url.PathEscape(roomID)+"/members", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Federation-Secret", peer.Secret)
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("peer %s returned %d", peer.URL, resp.StatusCode)
	}
	var out []map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out, nil
}

// RoomModerate asks the room's home [peer] to perform a moderation action on
// behalf of [actor] (kick / ban / unban / promote / demote).
func (c *Client) RoomModerate(peer *db.FederationPeer, roomID, actor, action, target string, durationSecs int64) error {
	return c.postJSON(peer, "/s2s/room/moderate", map[string]any{
		"room_id": roomID, "actor": actor, "action": action,
		"target": target, "duration_secs": durationSecs,
	})
}

// NotifyKicked tells a peer to disconnect a kicked/banned user from a room.
func (c *Client) NotifyKicked(peer *db.FederationPeer, roomID, userID string) error {
	return c.postJSON(peer, "/s2s/room/kicked",
		map[string]any{"room_id": roomID, "user_id": userID})
}

func (c *Client) postJSON(peer *db.FederationPeer, path string, v any) error {
	body, err := json.Marshal(v)
	if err != nil {
		return err
	}
	req, err := http.NewRequest("POST", peer.URL+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Federation-Secret", peer.Secret)

	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusAccepted {
		return fmt.Errorf("s2s %s to %s failed: status %d", path, peer.URL, resp.StatusCode)
	}
	return nil
}
