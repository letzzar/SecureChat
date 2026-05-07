import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:securechat/crypto/identity.dart';
import 'package:securechat/crypto/message_crypto.dart';
import 'package:securechat/crypto/noise_handshake.dart';
import 'package:securechat/crypto/signatures.dart';
import 'package:securechat/models/message.dart';
import 'package:securechat/network/ws_client.dart';
import 'package:securechat/store/app_state.dart';
import 'package:securechat/store/dm_voice_store.dart';
import 'package:securechat/store/file_transfer_store.dart';
import 'package:securechat/store/rooms_store.dart';
import 'package:securechat/store/voice_store.dart';

// ── Conversation messages ─────────────────────────────────────────────────────

class ConversationState {
  final Map<String, List<ChatMessage>> byPeer;
  const ConversationState({required this.byPeer});

  ConversationState withMessage(String peerId, ChatMessage msg) {
    final updated = Map<String, List<ChatMessage>>.from(byPeer);
    updated[peerId] = [...(updated[peerId] ?? []), msg];
    return ConversationState(byPeer: updated);
  }

  ConversationState updateStatus(String peerId, String msgId, MessageStatus status) {
    final updated = Map<String, List<ChatMessage>>.from(byPeer);
    updated[peerId] = (updated[peerId] ?? [])
        .map((m) => m.id == msgId ? m.copyWith(status: status) : m)
        .toList();
    return ConversationState(byPeer: updated);
  }
}

class ConversationNotifier extends Notifier<ConversationState> {
  @override
  ConversationState build() => const ConversationState(byPeer: {});

  void addMessage(String peerId, ChatMessage msg) {
    state = state.withMessage(peerId, msg);
  }

  void markDelivered(String peerId, String msgId) {
    state = state.updateStatus(peerId, msgId, MessageStatus.delivered);
  }

  void markFailed(String peerId, String msgId) {
    state = state.updateStatus(peerId, msgId, MessageStatus.failed);
  }

  void removeConversation(String peerId) {
    final updated = Map<String, List<ChatMessage>>.from(state.byPeer);
    updated.remove(peerId);
    state = ConversationState(byPeer: updated);
  }
}

final conversationProvider =
    NotifierProvider<ConversationNotifier, ConversationState>(ConversationNotifier.new);

// ── WebSocket client ──────────────────────────────────────────────────────────

final wsClientProvider = Provider<WsClient?>((ref) {
  final identity = ref.watch(sessionProvider).identity;
  if (identity == null) return null;

  final client = WsClient(serverUrl: identity.serverUrl, jwt: identity.jwt);
  client.connect();
  ref.onDispose(client.dispose);
  return client;
});

// ── Incoming message dispatcher ───────────────────────────────────────────────

/// Wire this in app.dart: ws.messages.listen((m) => dispatchIncoming(m, ref))
Future<void> dispatchIncoming(Map<String, dynamic> msg, WidgetRef ref) async {
  final type = msg['type'] as String? ?? '';
  final identity = ref.read(sessionProvider).identity;
  if (identity == null) return;

  switch (type) {
    case 'noise_init':
      await _onNoiseInit(msg, ref);
    case 'noise_resp':
      await _onNoiseResp(msg, ref);
    case 'dm':
      await _onDM(msg, identity, ref);
    case 'room_msg':
      await dispatchRoomMsg(msg, ref);

    case 'voice_joined':
      final participants = (msg['voice_participants'] as List<dynamic>?)
              ?.cast<String>() ??
          [];
      ref.read(voiceProvider.notifier).setParticipants(participants);

    case 'voice_user_joined':
      final from = msg['from'] as String? ?? '';
      if (from.isNotEmpty) ref.read(voiceProvider.notifier).addParticipant(from);

    case 'voice_user_left':
      final from = msg['from'] as String? ?? '';
      if (from.isNotEmpty) ref.read(voiceProvider.notifier).removeParticipant(from);

    case 'sdp_answer':
      final sdp = msg['sdp'] as String? ?? '';
      if (sdp.isNotEmpty) {
        await ref.read(voiceProvider.notifier).handleSdpAnswer(sdp);
      }

    case 'sdp_offer':
      final sdp = msg['sdp'] as String? ?? '';
      final roomId = msg['room_id'] as String? ?? '';
      if (sdp.isNotEmpty && roomId.isNotEmpty) {
        await ref.read(voiceProvider.notifier).handleSdpOffer(roomId, sdp);
      }

    case 'ice_candidate':
      final candidate = msg['candidate'] as String? ?? '';
      if (candidate.isNotEmpty) {
        await ref.read(voiceProvider.notifier).handleIceCandidate(candidate);
      }

    case 'delivered':
      final deliveredSeq = (msg['delivered_seq'] as int?) ?? 0;
      if (deliveredSeq > 0) {
        final entry = _pendingSeqs.remove(deliveredSeq);
        if (entry != null) {
          ref.read(conversationProvider.notifier)
              .markDelivered(entry.peerId, entry.msgId);
        }
      }

    case 'dm_call_offer':
      final fromId = msg['from'] as String? ?? '';
      final sdp = msg['sdp'] as String? ?? '';
      if (fromId.isNotEmpty && sdp.isNotEmpty) {
        final knownPeers = ref.read(knownPeersProvider);
        final displayName =
            knownPeers[fromId]?['display_name'] as String? ??
                fromId.substring(0, 12);
        ref.read(dmCallProvider.notifier).onIncomingOffer(fromId, displayName, sdp);
      }

    case 'dm_call_answer':
      final sdp = msg['sdp'] as String? ?? '';
      if (sdp.isNotEmpty) await ref.read(dmCallProvider.notifier).onAnswer(sdp);

    case 'dm_call_reject':
    case 'dm_call_end':
      ref.read(dmCallProvider.notifier).onRemoteEnd();

    case 'dm_ice_candidate':
      final candidate = msg['candidate'] as String? ?? '';
      if (candidate.isNotEmpty) {
        await ref.read(dmCallProvider.notifier).onIceCandidate(candidate);
      }

    case 'file_offer':
      await _onFileOffer(msg, identity, ref);

    case 'file_accept':
      final fileId = msg['file_id'] as String? ?? '';
      final fromId = msg['from'] as String? ?? '';
      if (fileId.isNotEmpty) {
        ref.read(fileTransferProvider.notifier).onFileAccepted(fileId, fromId);
      }

    case 'file_chunk':
      await _onFileChunk(msg, ref);

    case 'file_reject':
      final fileId = msg['file_id'] as String? ?? '';
      if (fileId.isNotEmpty) {
        ref.read(fileTransferProvider.notifier).updateStatus(fileId, FileTransferStatus.rejected);
      }

    case 'file_cancel':
      final fileId = msg['file_id'] as String? ?? '';
      if (fileId.isNotEmpty) {
        ref.read(fileTransferProvider.notifier).updateStatus(fileId, FileTransferStatus.cancelled);
      }

    case 'file_done':
      final fileId = msg['file_id'] as String? ?? '';
      if (fileId.isNotEmpty) {
        ref.read(fileTransferProvider.notifier).onDone(fileId);
      }

    case 'file_error':
      final fileId = msg['file_id'] as String? ?? '';
      if (fileId.isNotEmpty) {
        ref.read(fileTransferProvider.notifier).updateStatus(fileId, FileTransferStatus.error);
      }
  }
}

Future<void> _onFileOffer(
    Map<String, dynamic> msg, LocalIdentity identity, WidgetRef ref) async {
  final fromId = msg['from'] as String? ?? '';
  final fileId = msg['file_id'] as String? ?? '';
  if (fileId.isEmpty || fromId.isEmpty) return;

  var knownPeers = ref.read(knownPeersProvider);
  String peerPubHex = knownPeers[fromId]?['public_key'] as String? ?? '';
  if (peerPubHex.isEmpty) {
    try {
      final data = await ref.read(apiClientProvider)?.getUser(fromId);
      if (data != null) {
        ref.read(knownPeersProvider.notifier).update((s) => {...s, fromId: data});
        peerPubHex = data['public_key'] as String? ?? '';
      }
    } catch (_) {
      return;
    }
  }

  final sessionKey = getSession(peerPubHex);
  if (sessionKey == null) return;

  String fileName;
  int fileSize;
  try {
    final decrypted = await decryptMessage(
      nonceB64: msg['nonce'] as String? ?? '',
      ciphertextB64: msg['payload'] as String? ?? '',
      key: sessionKey,
    );
    final meta = jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>;
    fileName = meta['name'] as String;
    fileSize = meta['size'] as int;
  } catch (_) {
    return;
  }

  await ref.read(fileTransferProvider.notifier).onIncomingOffer(
        fileId: fileId,
        fromId: fromId,
        peerPubHex: peerPubHex,
        fileName: fileName,
        fileSize: fileSize,
        myUserId: identity.userId,
      );
}

Future<void> _onFileChunk(Map<String, dynamic> msg, WidgetRef ref) async {
  final fileId = msg['file_id'] as String? ?? '';
  final chunkIndex = msg['chunk_index'] as int? ?? 0;
  final chunkTotal = msg['chunk_total'] as int? ?? 0;
  if (fileId.isEmpty) return;

  final ft = ref.read(fileTransferProvider)[fileId];
  if (ft == null || ft.isOutgoing) return;

  final sessionKey = getSession(ft.peerPubHex);
  if (sessionKey == null) return;

  try {
    final decrypted = await decryptMessage(
      nonceB64: msg['nonce'] as String? ?? '',
      ciphertextB64: msg['payload'] as String? ?? '',
      key: sessionKey,
    );
    await ref.read(fileTransferProvider.notifier).onChunkReceived(
          fileId: fileId,
          chunkIndex: chunkIndex,
          chunkTotal: chunkTotal,
          decryptedChunk: decrypted,
        );
  } catch (_) {}
}

Future<void> _onNoiseInit(Map<String, dynamic> msg, WidgetRef ref) async {
  final fromId = msg['from'] as String? ?? '';
  final api = ref.read(apiClientProvider);
  if (api == null) return;

  Map<String, dynamic> peerData;
  try {
    peerData = await api.getUser(fromId);
  } catch (_) {
    return;
  }
  ref.read(knownPeersProvider.notifier).update((s) => {...s, fromId: peerData});

  final peerStaticPubHex = peerData['public_key'] as String? ?? '';

  NoiseRespData resp;
  try {
    resp = await processNoiseInit(
      senderStaticPubHex: peerStaticPubHex,
      ePubHex: msg['e_pub'] as String? ?? '',
      nonce: msg['nonce'] as String? ?? '',
      payload: msg['payload'] as String? ?? '',
    );
  } catch (_) {
    return; // Handshake failed — don't crash the queue
  }

  final signPayload = utf8.encode('noise_resp:$fromId:${resp.nonce}:${resp.payload}');
  final sig = await signData(signPayload);

  ref.read(wsClientProvider)?.send({
    'type': 'noise_resp',
    'to': fromId,
    'nonce': resp.nonce,
    'payload': resp.payload,
    'sig': sig,
    'seq': 0,
    'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  });
}

Future<void> _onNoiseResp(Map<String, dynamic> msg, WidgetRef ref) async {
  final fromId = msg['from'] as String? ?? '';
  final knownPeers = ref.read(knownPeersProvider);
  final peerStaticPubHex = knownPeers[fromId]?['public_key'] as String? ?? '';
  if (peerStaticPubHex.isEmpty) return;

  try {
    await processNoiseResp(
      peerStaticPubHex: peerStaticPubHex,
      nonce: msg['nonce'] as String? ?? '',
      payload: msg['payload'] as String? ?? '',
    );
  } catch (_) {}
}

Future<void> _onDM(Map<String, dynamic> msg, LocalIdentity identity, WidgetRef ref) async {
  final fromId = msg['from'] as String? ?? '';

  // Silently drop messages from blocked users
  if (ref.read(blockedUsersProvider).contains(fromId)) return;

  // Fetch peer key if unknown
  if (!ref.read(knownPeersProvider).containsKey(fromId)) {
    try {
      final data = await ref.read(apiClientProvider)?.getUser(fromId);
      if (data != null) {
        ref.read(knownPeersProvider.notifier).update((s) => {...s, fromId: data});
      }
    } catch (_) {
      return;
    }
  }

  final peerStaticPubHex = ref.read(knownPeersProvider)[fromId]?['public_key'] as String? ?? '';
  final sessionKey = getSession(peerStaticPubHex);
  if (sessionKey == null) return;

  String text;
  try {
    final decrypted = await decryptMessage(
      nonceB64: msg['nonce'] as String? ?? '',
      ciphertextB64: msg['payload'] as String? ?? '',
      key: sessionKey,
    );
    text = utf8.decode(decrypted);
  } catch (_) {
    text = '[decryption failed]';
  }

  final ts = (msg['ts'] as int?) ?? 0;
  final incoming = ChatMessage(
    id: '${fromId}_${msg['seq'] ?? ts}',
    fromUserId: fromId,
    toUserId: identity.userId,
    text: text,
    timestamp: ts > 0
        ? DateTime.fromMillisecondsSinceEpoch(ts * 1000)
        : DateTime.now(),
    isOutgoing: false,
    status: MessageStatus.delivered,
  );

  // Route to contact request if sender is not an accepted contact
  if (!ref.read(acceptedContactsProvider).contains(fromId)) {
    final peerData = ref.read(knownPeersProvider)[fromId];
    final displayName = peerData?['display_name'] as String? ?? fromId.substring(0, 12);
    ref.read(contactRequestsProvider.notifier).addOrAppend(ContactRequest(
      fromId: fromId,
      displayName: displayName,
      pubHex: peerStaticPubHex,
      messages: [incoming],
    ));
    return;
  }

  ref.read(conversationProvider.notifier).addMessage(fromId, incoming);
}

// ── Pending delivery acks (seq → {peerId, msgId}) ────────────────────────────

final _pendingSeqs = <int, ({String peerId, String msgId})>{};

// ── Send DM ───────────────────────────────────────────────────────────────────

final _rng = Random.secure();

String _uuid() {
  final b = Uint8List(16);
  for (var i = 0; i < 16; i++) { b[i] = _rng.nextInt(256); }
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = bytesToHex(b);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Send an encrypted DM. Initiates Noise handshake if needed.
/// Returns the local message ID, or null if handshake is pending.
Future<String?> sendDM({
  required WidgetRef ref,
  required String myUserId,
  required String peerUserId,
  required String peerStaticPubHex,
  required String text,
}) async {
  final ws = ref.read(wsClientProvider);
  if (ws == null) throw StateError('WebSocket not connected');

  final msgId = _uuid();
  final seq = DateTime.now().millisecondsSinceEpoch;

  // If no session yet, start handshake first (message will be sent after noise_resp)
  if (!hasSession(peerStaticPubHex)) {
    // Cache peer pub only if not already known (avoid overwriting display_name)
    ref.read(knownPeersProvider.notifier).update((s) {
      if (s.containsKey(peerUserId)) return s;
      return {...s, peerUserId: {'user_id': peerUserId, 'public_key': peerStaticPubHex}};
    });

    final initData = await buildNoiseInit(
      myUserId: myUserId,
      peerStaticPubHex: peerStaticPubHex,
    );
    final signPayload = utf8.encode('noise_init:$peerUserId:${initData.nonce}:${initData.payload}');
    final sig = await signData(signPayload);

    ws.send({
      'type': 'noise_init',
      'to': peerUserId,
      'e_pub': initData.ePubHex,
      'nonce': initData.nonce,
      'payload': initData.payload,
      'sig': sig,
      'seq': 0,
      'ts': seq ~/ 1000,
    });
    // Session key is now in memory (from buildNoiseInit), but we wait for noise_resp to confirm.
    // Optimistically continue — if the peer is offline, the message will fail gracefully.
  }

  final sessionKey = getSession(peerStaticPubHex);
  if (sessionKey == null) {
    // Still no session after init — peer is offline or unreachable
    return null;
  }

  final enc = await encryptMessage(utf8.encode(text), sessionKey);
  final signPayload = utf8.encode('dm:$peerUserId:${enc.nonce}:${enc.ciphertext}:$seq');
  final sig = await signData(signPayload);

  // Mark peer as accepted so their replies come through directly
  ref.read(acceptedContactsProvider.notifier).update((s) => {...s, peerUserId});

  // Optimistic local message
  final outgoing = ChatMessage(
    id: msgId,
    fromUserId: myUserId,
    toUserId: peerUserId,
    text: text,
    timestamp: DateTime.now(),
    isOutgoing: true,
    status: MessageStatus.sending,
  );
  ref.read(conversationProvider.notifier).addMessage(peerUserId, outgoing);

  _pendingSeqs[seq] = (peerId: peerUserId, msgId: msgId);

  ws.send({
    'type': 'dm',
    'to': peerUserId,
    'nonce': enc.nonce,
    'payload': enc.ciphertext,
    'sig': sig,
    'seq': seq,
    'ts': seq ~/ 1000,
  });

  return msgId;
}
