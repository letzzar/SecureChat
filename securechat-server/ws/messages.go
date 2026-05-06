package ws

// IncomingMessage is the top-level envelope for all client→server WebSocket messages.
type IncomingMessage struct {
	Type string `json:"type"`

	// dm / noise_init / noise_resp
	To      string `json:"to,omitempty"`
	Nonce   string `json:"nonce,omitempty"`
	Payload string `json:"payload,omitempty"`
	Sig     string `json:"sig,omitempty"`
	Seq     int64  `json:"seq,omitempty"`
	Ts      int64  `json:"ts,omitempty"`
	EPub    string `json:"e_pub,omitempty"` // ephemeral public key (noise_init)

	// room_join / room_leave / room_msg
	RoomID string `json:"room_id,omitempty"`

	// voice signaling
	SDP       string `json:"sdp,omitempty"`
	Candidate string `json:"candidate,omitempty"`
}

// OutgoingMessage is the top-level envelope for all server→client WebSocket messages.
type OutgoingMessage struct {
	Type string `json:"type"`

	// dm / noise_init / noise_resp
	From    string `json:"from,omitempty"`
	To      string `json:"to,omitempty"`
	Nonce   string `json:"nonce,omitempty"`
	Payload string `json:"payload,omitempty"`
	Sig     string `json:"sig,omitempty"`
	Seq     int64  `json:"seq,omitempty"`
	Ts      int64  `json:"ts,omitempty"`
	EPub    string `json:"e_pub,omitempty"`

	// room messages
	RoomID string `json:"room_id,omitempty"`

	// delivery ack
	DeliveredSeq int64 `json:"delivered_seq,omitempty"`

	// voice signaling
	SDP               string   `json:"sdp,omitempty"`
	Candidate         string   `json:"candidate,omitempty"`
	VoiceParticipants []string `json:"voice_participants,omitempty"`

	// error
	Code string `json:"code,omitempty"`
	Msg  string `json:"msg,omitempty"`
}
