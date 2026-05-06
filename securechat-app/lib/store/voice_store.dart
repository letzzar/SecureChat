import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:securechat/store/app_state.dart';
import 'package:securechat/store/messages_store.dart';
import 'package:securechat/voice/voice_client.dart';

class VoiceState {
  final String? activeRoomId;
  final bool muted;
  final List<String> participants;

  const VoiceState({
    this.activeRoomId,
    this.muted = false,
    this.participants = const [],
  });

  bool get inCall => activeRoomId != null;

  VoiceState copyWith({
    String? activeRoomId,
    bool? muted,
    List<String>? participants,
    bool clearRoom = false,
  }) {
    return VoiceState(
      activeRoomId: clearRoom ? null : (activeRoomId ?? this.activeRoomId),
      muted: muted ?? this.muted,
      participants: participants ?? this.participants,
    );
  }
}

class VoiceNotifier extends Notifier<VoiceState> {
  VoiceClient? _client;

  @override
  VoiceState build() => const VoiceState();

  Future<void> join(String roomId) async {
    final ws = ref.read(wsClientProvider);
    final identity = ref.read(sessionProvider).identity;
    if (ws == null || identity == null) return;

    _client ??= VoiceClient(ws: ws, myUserId: identity.userId);
    await _client!.join(roomId);
    state = VoiceState(activeRoomId: roomId);
  }

  Future<void> leave() async {
    await _client?.leave();
    state = const VoiceState();
  }

  bool toggleMute() {
    final muted = _client?.toggleMute() ?? false;
    state = state.copyWith(muted: muted);
    return muted;
  }

  void setParticipants(List<String> ids) {
    state = state.copyWith(participants: ids);
  }

  void addParticipant(String userId) {
    if (!state.participants.contains(userId)) {
      state = state.copyWith(participants: [...state.participants, userId]);
    }
  }

  void removeParticipant(String userId) {
    state = state.copyWith(
      participants: state.participants.where((id) => id != userId).toList(),
    );
  }

  Future<void> handleSdpAnswer(String sdp) async {
    await _client?.handleSdpAnswer(sdp);
  }

  Future<void> handleSdpOffer(String roomId, String sdp) async {
    await _client?.handleSdpOffer(roomId, sdp);
  }

  Future<void> handleIceCandidate(String candidateJson) async {
    await _client?.handleIceCandidate(candidateJson);
  }

  Future<void> disposeClient() async {
    await _client?.dispose();
    _client = null;
  }
}

final voiceProvider = NotifierProvider<VoiceNotifier, VoiceState>(VoiceNotifier.new);
