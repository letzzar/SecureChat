import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:securechat/network/ws_client.dart';
import 'package:securechat/store/messages_store.dart';

enum DmCallStatus { idle, calling, ringing, inCall }

class DmCallState {
  final DmCallStatus status;
  final String? peerId;
  final String? peerDisplayName;
  final bool muted;

  const DmCallState({
    this.status = DmCallStatus.idle,
    this.peerId,
    this.peerDisplayName,
    this.muted = false,
  });

  bool get isActive => status != DmCallStatus.idle;

  DmCallState copyWith({
    DmCallStatus? status,
    String? peerId,
    String? peerDisplayName,
    bool? muted,
  }) =>
      DmCallState(
        status: status ?? this.status,
        peerId: peerId ?? this.peerId,
        peerDisplayName: peerDisplayName ?? this.peerDisplayName,
        muted: muted ?? this.muted,
      );
}

class DmCallNotifier extends Notifier<DmCallState> {
  webrtc.RTCPeerConnection? _pc;
  webrtc.MediaStream? _localStream;
  String? _pendingOfferSdp;

  @override
  DmCallState build() => const DmCallState();

  Future<void> startCall(String peerId, String peerDisplayName) async {
    if (state.isActive) return;
    final ws = ref.read(wsClientProvider);
    if (ws == null) return;

    state = DmCallState(
      status: DmCallStatus.calling,
      peerId: peerId,
      peerDisplayName: peerDisplayName,
    );

    try {
      await _setupPeerConnection(peerId, ws);
      final offer = await _pc!.createOffer({});
      await _pc!.setLocalDescription(offer);
      ws.send({'type': 'dm_call_offer', 'to': peerId, 'sdp': offer.sdp});
    } catch (_) {
      await _teardown();
    }
  }

  void onIncomingOffer(String peerId, String peerDisplayName, String sdp) {
    if (state.isActive) {
      // Already busy — auto-reject
      ref.read(wsClientProvider)?.send({'type': 'dm_call_reject', 'to': peerId});
      return;
    }
    _pendingOfferSdp = sdp;
    state = DmCallState(
      status: DmCallStatus.ringing,
      peerId: peerId,
      peerDisplayName: peerDisplayName,
    );
  }

  Future<void> acceptCall() async {
    final peerId = state.peerId;
    final offerSdp = _pendingOfferSdp;
    if (peerId == null || offerSdp == null) return;
    final ws = ref.read(wsClientProvider);
    if (ws == null) return;

    state = state.copyWith(status: DmCallStatus.inCall);

    try {
      await _setupPeerConnection(peerId, ws);
      await _pc!.setRemoteDescription(
          webrtc.RTCSessionDescription(offerSdp, 'offer'));
      final answer = await _pc!.createAnswer({});
      await _pc!.setLocalDescription(answer);
      ws.send({'type': 'dm_call_answer', 'to': peerId, 'sdp': answer.sdp});
      _pendingOfferSdp = null;
    } catch (_) {
      await _teardown();
    }
  }

  Future<void> rejectCall() async {
    final peerId = state.peerId;
    if (peerId != null) {
      ref.read(wsClientProvider)?.send(
          {'type': 'dm_call_reject', 'to': peerId});
    }
    await _teardown();
  }

  Future<void> onAnswer(String sdp) async {
    await _pc?.setRemoteDescription(
        webrtc.RTCSessionDescription(sdp, 'answer'));
    state = state.copyWith(status: DmCallStatus.inCall);
  }

  Future<void> onIceCandidate(String candidateJson) async {
    if (_pc == null) return;
    final map = jsonDecode(candidateJson) as Map<String, dynamic>;
    await _pc!.addCandidate(webrtc.RTCIceCandidate(
      map['candidate'] as String?,
      map['sdpMid'] as String?,
      map['sdpMLineIndex'] as int?,
    ));
  }

  void onRemoteEnd() => _teardown();

  Future<void> endCall() async {
    final peerId = state.peerId;
    if (peerId != null) {
      ref.read(wsClientProvider)?.send({'type': 'dm_call_end', 'to': peerId});
    }
    await _teardown();
  }

  bool toggleMute() {
    final muted = !state.muted;
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !muted);
    state = state.copyWith(muted: muted);
    return muted;
  }

  Future<void> _setupPeerConnection(String peerId, WsClient ws) async {
    _localStream = await webrtc.navigator.mediaDevices
        .getUserMedia({'audio': true, 'video': false});

    _pc = await webrtc.createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });

    for (final track in _localStream!.getAudioTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    _pc!.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        ws.send({
          'type': 'dm_ice_candidate',
          'to': peerId,
          'candidate': jsonEncode(candidate.toMap()),
        });
      }
    };
  }

  Future<void> _teardown() async {
    _pendingOfferSdp = null;
    await _localStream?.dispose();
    _localStream = null;
    await _pc?.close();
    _pc = null;
    state = const DmCallState();
  }
}

final dmCallProvider =
    NotifierProvider<DmCallNotifier, DmCallState>(DmCallNotifier.new);
