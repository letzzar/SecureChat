package db

import (
	"database/sql"
	"time"
)

type FederationPeer struct {
	ID       int64
	URL      string
	Name     string
	Secret   string
	AddedAt  int64
	LastSeen *int64
}

func AddFederationPeer(database *sql.DB, peerURL, name, secret string) error {
	_, err := database.Exec(
		`INSERT OR REPLACE INTO federation_peers (url, name, secret, added_at) VALUES (?, ?, ?, ?)`,
		peerURL, name, secret, time.Now().Unix(),
	)
	return err
}

func GetFederationPeers(database *sql.DB) ([]*FederationPeer, error) {
	rows, err := database.Query(
		`SELECT id, url, name, secret, added_at, last_seen FROM federation_peers ORDER BY id`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var peers []*FederationPeer
	for rows.Next() {
		p := &FederationPeer{}
		if err := rows.Scan(&p.ID, &p.URL, &p.Name, &p.Secret, &p.AddedAt, &p.LastSeen); err != nil {
			return nil, err
		}
		peers = append(peers, p)
	}
	return peers, rows.Err()
}

func DeleteFederationPeer(database *sql.DB, peerURL string) error {
	_, err := database.Exec(`DELETE FROM federation_peers WHERE url = ?`, peerURL)
	return err
}

func UpdateFederationPeerSeen(database *sql.DB, peerURL string) {
	now := time.Now().Unix()
	database.Exec(`UPDATE federation_peers SET last_seen = ? WHERE url = ?`, now, peerURL)
}
