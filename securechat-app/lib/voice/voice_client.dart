import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:securechat/network/ws_client.dart';

/// Manages the WebRTC peer connection for a single voice room session.
///
/// Audio is end-to-end encrypted at the frame level (WebRTC insertable
/// streams / FrameCryptor) with the shared room key, so the SFU forwards
/// opaque frames and cannot hear the audio (design §9).
class VoiceClient {
  final WsClient _ws;
  final String _myUserId;

  webrtc.RTCPeerConnection? _pc;
  webrtc.MediaStream? _localStream;
  String? _activeRoomId;

  // E2E media encryption state.
  webrtc.KeyProvider? _keyProvider;
  final List<webrtc.FrameCryptor> _cryptors = [];
  int _cryptorSeq = 0;

  bool _muted = false;
  bool get muted => _muted;
  bool get inCall => _activeRoomId != null;

  VoiceClient({required WsClient ws, required String myUserId})
      : _ws = ws,
        _myUserId = myUserId;

  // Fixed salt shared by all clients so everyone derives the same media key
  // from the shared room key. Must be identical across peers.
  static final Uint8List _ratchetSalt =
      Uint8List.fromList(utf8.encode('securechat-e2ee-voice-v1'));

  /// Join the voice channel of [roomId]. [roomKey] is the 32-byte room key;
  /// all voice media is end-to-end encrypted with it.
  Future<void> join(String roomId, Uint8List roomKey) async {
    if (_activeRoomId != null) await leave();

    // Shared-key provider for frame encryption (same key + salt on every peer,
    // so all members derive the same media key; the SFU has neither).
    _keyProvider = await webrtc.frameCryptorFactory.createDefaultKeyProvider(
      webrtc.KeyProviderOptions(
        sharedKey: true,
        ratchetSalt: _ratchetSalt,
        ratchetWindowSize: 16,
        failureTolerance: -1,
      ),
    );
    await _keyProvider!.setSharedKey(key: roomKey, index: 0);

    // Request microphone access
    _localStream = await webrtc.navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });

    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    };

    _pc = await webrtc.createPeerConnection(config);
    _activeRoomId = roomId;

    // Add local audio tracks and encrypt outgoing frames.
    for (final track in _localStream!.getAudioTracks()) {
      final sender = await _pc!.addTrack(track, _localStream!);
      await _attachCryptorToSender(sender);
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

    // Decrypt incoming frames from each remote participant.
    _pc!.onTrack = (event) {
      final receiver = event.receiver;
      if (receiver != null) {
        _attachCryptorToReceiver(receiver);
      }
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
    await _pc?.setRemoteDescription(webrtc.RTCSessionDescription(sdp, 'answer'));
  }

  /// Process a renegotiation offer from the server (new participant joined).
  Future<void> handleSdpOffer(String roomId, String sdp) async {
    if (_pc == null) return;
    await _pc!.setRemoteDescription(webrtc.RTCSessionDescription(sdp, 'offer'));
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
    await _pc!.addCandidate(webrtc.RTCIceCandidate(
      map['candidate'] as String?,
      map['sdpMid'] as String?,
      map['sdpMLineIndex'] as int?,
    ));
  }

  /// Encrypt outgoing audio frames on [sender] with the shared room key.
  Future<void> _attachCryptorToSender(webrtc.RTCRtpSender sender) async {
    final fc = await webrtc.frameCryptorFactory.createFrameCryptorForRtpSender(
      participantId: '${_myUserId}_snd_${_cryptorSeq++}',
      sender: sender,
      algorithm: webrtc.Algorithm.kAesGcm,
      keyProvider: _keyProvider!,
    );
    await fc.setKeyIndex(0);
    await fc.setEnabled(true);
    _cryptors.add(fc);
  }

  /// Decrypt incoming audio frames on [receiver] with the shared room key.
  Future<void> _attachCryptorToReceiver(webrtc.RTCRtpReceiver receiver) async {
    final fc = await webrtc.frameCryptorFactory.createFrameCryptorForRtpReceiver(
      participantId: 'rcv_${_cryptorSeq++}',
      receiver: receiver,
      algorithm: webrtc.Algorithm.kAesGcm,
      keyProvider: _keyProvider!,
    );
    await fc.setKeyIndex(0);
    await fc.setEnabled(true);
    _cryptors.add(fc);
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

    for (final fc in _cryptors) {
      await fc.dispose();
    }
    _cryptors.clear();
    await _keyProvider?.dispose();
    _keyProvider = null;

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
