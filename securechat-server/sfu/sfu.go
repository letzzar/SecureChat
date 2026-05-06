package sfu

import (
	"encoding/json"
	"fmt"
	"log"
	"sync"

	"github.com/pion/webrtc/v3"
)

// SendFunc delivers a signaling message back to a specific client.
type SendFunc func(msgType, payload, roomID string)

// OnPeerLeftFunc is called when a peer disconnects from a voice room.
type OnPeerLeftFunc func(roomID, userID string)

// SFU manages WebRTC peer connections grouped by voice room.
type SFU struct {
	mu         sync.RWMutex
	rooms      map[string]*voiceRoom
	iceServers []webrtc.ICEServer
	onPeerLeft OnPeerLeftFunc
}

type voiceRoom struct {
	mu    sync.RWMutex
	peers map[string]*voicePeer
}

type voicePeer struct {
	userID string
	roomID string
	pc     *webrtc.PeerConnection
	send   SendFunc

	trackMu        sync.Mutex
	publishedTrack *webrtc.TrackLocalStaticRTP
}

func New(iceServers []webrtc.ICEServer) *SFU {
	if len(iceServers) == 0 {
		iceServers = []webrtc.ICEServer{
			{URLs: []string{"stun:stun.l.google.com:19302"}},
		}
	}
	return &SFU{
		rooms:      make(map[string]*voiceRoom),
		iceServers: iceServers,
	}
}

func (s *SFU) SetOnPeerLeft(fn OnPeerLeftFunc) {
	s.onPeerLeft = fn
}

// Join creates a PeerConnection for a user entering a voice room.
func (s *SFU) Join(roomID, userID string, send SendFunc) error {
	room := s.getOrCreateRoom(roomID)

	pc, err := webrtc.NewPeerConnection(webrtc.Configuration{ICEServers: s.iceServers})
	if err != nil {
		return fmt.Errorf("new peer connection: %w", err)
	}

	// Declare that the SFU will receive audio from this peer
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeAudio, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	}); err != nil {
		pc.Close()
		return fmt.Errorf("add transceiver: %w", err)
	}

	peer := &voicePeer{userID: userID, roomID: roomID, pc: pc, send: send}

	// Trickle ICE: send candidates to client as they are gathered
	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			return
		}
		data, _ := json.Marshal(c.ToJSON())
		send("ice_candidate", string(data), roomID)
	})

	// Handle incoming audio track from this client
	pc.OnTrack(func(remote *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		if remote.Kind() != webrtc.RTPCodecTypeAudio {
			return
		}
		local, err := webrtc.NewTrackLocalStaticRTP(
			remote.Codec().RTPCodecCapability,
			"audio",
			"sfu-"+userID,
		)
		if err != nil {
			log.Printf("sfu OnTrack [%s]: %v", userID, err)
			return
		}

		peer.trackMu.Lock()
		peer.publishedTrack = local
		peer.trackMu.Unlock()

		// Forward this track to all other peers (triggers renegotiation)
		s.distributeTrack(roomID, userID, local)

		// Pipe RTP packets from remote → local static track → other peers
		buf := make([]byte, 1400)
		for {
			n, _, err := remote.Read(buf)
			if err != nil {
				return
			}
			if _, err = local.Write(buf[:n]); err != nil {
				return
			}
		}
	})

	// Auto-leave on connection failure/disconnect
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		switch state {
		case webrtc.PeerConnectionStateFailed,
			webrtc.PeerConnectionStateClosed,
			webrtc.PeerConnectionStateDisconnected:
			s.Leave(roomID, userID)
		}
	})

	// Register peer and collect existing published tracks
	room.mu.Lock()
	room.peers[userID] = peer
	var existingTracks []*webrtc.TrackLocalStaticRTP
	for uid, p := range room.peers {
		if uid == userID {
			continue
		}
		p.trackMu.Lock()
		if p.publishedTrack != nil {
			existingTracks = append(existingTracks, p.publishedTrack)
		}
		p.trackMu.Unlock()
	}
	room.mu.Unlock()

	// Add existing participants' tracks so new peer can hear them immediately
	for _, t := range existingTracks {
		if _, err := pc.AddTrack(t); err != nil {
			log.Printf("sfu Join: add existing track to %s: %v", userID, err)
		}
	}

	return nil
}

// Leave removes a peer from a voice room and closes their connection.
func (s *SFU) Leave(roomID, userID string) {
	s.mu.RLock()
	room, ok := s.rooms[roomID]
	s.mu.RUnlock()
	if !ok {
		return
	}

	room.mu.Lock()
	peer, exists := room.peers[userID]
	if exists {
		delete(room.peers, userID)
	}
	empty := len(room.peers) == 0
	room.mu.Unlock()

	if !exists {
		return
	}
	peer.pc.Close()

	if empty {
		s.mu.Lock()
		delete(s.rooms, roomID)
		s.mu.Unlock()
	}

	if s.onPeerLeft != nil {
		s.onPeerLeft(roomID, userID)
	}
}

// HandleOffer processes a client's SDP offer and returns an SDP answer.
func (s *SFU) HandleOffer(roomID, userID, sdp string) (string, error) {
	peer := s.getPeer(roomID, userID)
	if peer == nil {
		return "", fmt.Errorf("peer not in room %s", roomID)
	}

	if err := peer.pc.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP:  sdp,
	}); err != nil {
		return "", fmt.Errorf("set remote description: %w", err)
	}

	answer, err := peer.pc.CreateAnswer(nil)
	if err != nil {
		return "", fmt.Errorf("create answer: %w", err)
	}

	if err := peer.pc.SetLocalDescription(answer); err != nil {
		return "", fmt.Errorf("set local description: %w", err)
	}

	return peer.pc.LocalDescription().SDP, nil
}

// HandleAnswer processes a client's SDP answer (renegotiation response).
func (s *SFU) HandleAnswer(roomID, userID, sdp string) error {
	peer := s.getPeer(roomID, userID)
	if peer == nil {
		return fmt.Errorf("peer not in room %s", roomID)
	}
	return peer.pc.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer,
		SDP:  sdp,
	})
}

// HandleICECandidate adds a remote ICE candidate from a client.
func (s *SFU) HandleICECandidate(roomID, userID, candidateJSON string) error {
	peer := s.getPeer(roomID, userID)
	if peer == nil {
		return fmt.Errorf("peer not in room %s", roomID)
	}
	var init webrtc.ICECandidateInit
	if err := json.Unmarshal([]byte(candidateJSON), &init); err != nil {
		return err
	}
	return peer.pc.AddICECandidate(init)
}

// Participants returns the user IDs of all active voice participants in a room.
func (s *SFU) Participants(roomID string) []string {
	s.mu.RLock()
	room, ok := s.rooms[roomID]
	s.mu.RUnlock()
	if !ok {
		return []string{}
	}
	room.mu.RLock()
	defer room.mu.RUnlock()
	ids := make([]string, 0, len(room.peers))
	for id := range room.peers {
		ids = append(ids, id)
	}
	return ids
}

// distributeTrack adds a newly published track to all other peers and triggers renegotiation.
func (s *SFU) distributeTrack(roomID, publisherID string, track *webrtc.TrackLocalStaticRTP) {
	s.mu.RLock()
	room, ok := s.rooms[roomID]
	s.mu.RUnlock()
	if !ok {
		return
	}

	room.mu.RLock()
	others := make([]*voicePeer, 0)
	for uid, p := range room.peers {
		if uid != publisherID {
			others = append(others, p)
		}
	}
	room.mu.RUnlock()

	for _, p := range others {
		if _, err := p.pc.AddTrack(track); err != nil {
			log.Printf("sfu distributeTrack: add to %s: %v", p.userID, err)
			continue
		}
		// Server initiates renegotiation so the peer gets the new track
		go func(peer *voicePeer) {
			offer, err := peer.pc.CreateOffer(nil)
			if err != nil {
				log.Printf("sfu renegotiate offer [%s]: %v", peer.userID, err)
				return
			}
			if err := peer.pc.SetLocalDescription(offer); err != nil {
				log.Printf("sfu renegotiate setlocal [%s]: %v", peer.userID, err)
				return
			}
			peer.send("sdp_offer", peer.pc.LocalDescription().SDP, peer.roomID)
		}(p)
	}
}

func (s *SFU) getOrCreateRoom(roomID string) *voiceRoom {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r, ok := s.rooms[roomID]; ok {
		return r
	}
	r := &voiceRoom{peers: make(map[string]*voicePeer)}
	s.rooms[roomID] = r
	return r
}

func (s *SFU) getPeer(roomID, userID string) *voicePeer {
	s.mu.RLock()
	room, ok := s.rooms[roomID]
	s.mu.RUnlock()
	if !ok {
		return nil
	}
	room.mu.RLock()
	defer room.mu.RUnlock()
	return room.peers[userID]
}
