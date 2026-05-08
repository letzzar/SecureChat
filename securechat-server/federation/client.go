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
	body, err := json.Marshal(msg)
	if err != nil {
		return err
	}

	req, err := http.NewRequest("POST", peer.URL+"/s2s/message", bytes.NewReader(body))
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
		return fmt.Errorf("relay to %s failed: status %d", peer.URL, resp.StatusCode)
	}
	return nil
}
