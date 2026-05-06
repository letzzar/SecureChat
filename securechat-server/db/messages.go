package db

import (
	"database/sql"
	"fmt"
	"time"
)

type OfflineMsg struct {
	ID          int64
	RecipientID string
	MsgType     string // dm, noise_init, noise_resp
	FromID      string
	Payload     string
	Nonce       string
	Sig         string
	Seq         int64
	EPub        string
	CreatedAt   int64
	ExpiresAt   int64
}

func SaveOfflineMessage(db *sql.DB, m *OfflineMsg) error {
	_, err := db.Exec(`
		INSERT INTO offline_messages
			(recipient_id, msg_type, from_id, payload, nonce, sig, seq, e_pub, created_at, expires_at)
		VALUES (?,?,?,?,?,?,?,?,?,?)`,
		m.RecipientID, m.MsgType, m.FromID, m.Payload, m.Nonce, m.Sig, m.Seq, m.EPub, m.CreatedAt, m.ExpiresAt,
	)
	if err != nil {
		return fmt.Errorf("save offline msg: %w", err)
	}
	return nil
}

func GetOfflineMessages(db *sql.DB, recipientID string) ([]*OfflineMsg, error) {
	now := time.Now().Unix()
	rows, err := db.Query(`
		SELECT id, msg_type, from_id, payload, nonce, sig, seq, e_pub
		FROM offline_messages
		WHERE recipient_id = ? AND expires_at > ?
		ORDER BY created_at ASC`,
		recipientID, now,
	)
	if err != nil {
		return nil, fmt.Errorf("get offline msgs: %w", err)
	}
	defer rows.Close()

	var msgs []*OfflineMsg
	for rows.Next() {
		m := &OfflineMsg{RecipientID: recipientID}
		if err := rows.Scan(&m.ID, &m.MsgType, &m.FromID, &m.Payload, &m.Nonce, &m.Sig, &m.Seq, &m.EPub); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	return msgs, rows.Err()
}

func DeleteOfflineMessages(db *sql.DB, recipientID string) error {
	_, err := db.Exec(`DELETE FROM offline_messages WHERE recipient_id = ?`, recipientID)
	return err
}

func DeleteExpiredMessages(db *sql.DB) error {
	_, err := db.Exec(`DELETE FROM offline_messages WHERE expires_at <= ?`, time.Now().Unix())
	return err
}
