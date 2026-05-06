import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:securechat/network/ws_client.dart';

/// Manages the WebRTC peer connection for a single voice room session.
class VoiceClient {
  final WsClient _ws;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  String? _activeRoomId;

  bool _muted = false;
  bool get muted => _muted;
  bool get inCall => _activeRoomId != null;

  VoiceClient({required WsClient ws, required String myUserId}) : _ws = ws;

  /// Join the voice channel of [roomId].
  Future<void> join(String roomId) async {
    if (_activeRoomId != null) await leave();

    // Request microphone access
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });

    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    };

    _pc = await createPeerConnection(config);
    _activeRoomId = roomId;

    // Add local audio tracks to the peer connection
    for (final track in _localStream!.getAudioTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    // Send ICE candidates to server as they are gathered (trickle ICE)
    _pc!.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        _ws.send({
          'type': 'ice_candidate',
          'room_id': roomId,
          'candidate': jsonEncode(candidate.toMap()),
        });
      }
    };

    // Remote audio is handled automatically by WebRTC engine
    _pc!.onTrack = (event) {
      // Audio playback is automatic on mobile
    };

    // Notify server we're joining
    _ws.send({'type': 'voice_join', 'room_id': roomId});

    // Create and send offer
    final offer = await _pc!.createOffer({});
    await _pc!.setLocalDescription(offer);
    _ws.send({
      'type': 'sdp_offer',
      'room_id': roomId,
      'sdp': offer.sdp,
    });
  }

  /// Process the SDP answer from the server (response to our offer).
  Future<void> handleSdpAnswer(String sdp) async {
    await _pc?.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  /// Process a renegotiation offer from the server (new participant joined).
  Future<void> handleSdpOffer(String roomId, String sdp) async {
    if (_pc == null) return;
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    final answer = await _pc!.createAnswer({});
    await _pc!.setLocalDescription(answer);
    _ws.send({
      'type': 'sdp_answer',
      'room_id': roomId,
      'sdp': answer.sdp,
    });
  }

  /// Add an ICE candidate received from the server.
  Future<void> handleIceCandidate(String candidateJson) async {
    if (_pc == null) return;
    final map = jsonDecode(candidateJson) as Map<String, dynamic>;
    await _pc!.addCandidate(RTCIceCandidate(
      map['candidate'] as String?,
      map['sdpMid'] as String?,
      map['sdpMLineIndex'] as int?,
    ));
  }

  /// Toggle microphone mute state. Returns the new muted state.
  bool toggleMute() {
    _muted = !_muted;
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !_muted);
    return _muted;
  }

  /// Leave the voice channel.
  Future<void> leave() async {
    final roomId = _activeRoomId;
    _activeRoomId = null;

    if (roomId != null) {
      _ws.send({'type': 'voice_leave', 'room_id': roomId});
    }

    await _localStream?.dispose();
    _localStream = null;

    await _pc?.close();
    _pc = null;

    _muted = false;
  }

  Future<void> dispose() async {
    await leave();
  }
}
