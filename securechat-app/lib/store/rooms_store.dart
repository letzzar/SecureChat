import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:securechat/crypto/identity.dart';
import 'package:securechat/crypto/room_crypto.dart';
import 'package:securechat/models/room.dart';
import 'package:securechat/network/ws_client.dart';
import 'package:securechat/store/app_state.dart';
import 'package:securechat/store/file_transfer_store.dart';

// ── Room keys (in-memory, never persisted) ────────────────────────────────────

final _roomKeys = <String, Uint8List>{}; // roomId → 32-byte key

Uint8List? getRoomKey(String roomId) => _roomKeys[roomId];
void _storeRoomKey(String roomId, Uint8List key) => _roomKeys[roomId] = key;
void _removeRoomKey(String roomId) => _roomKeys.remove(roomId);

// Persistence helpers (encrypted local store).
Map<String, Uint8List> exportRoomKeys() => Map.of(_roomKeys);
void restoreRoomKeys(Map<String, Uint8List> keys) => _roomKeys.addAll(keys);
void clearRoomKeys() => _roomKeys.clear(); // on account switch

// ── State ─────────────────────────────────────────────────────────────────────

class RoomsState {
  final List<JoinedRoom> joined;
  final Map<String, List<RoomMessage>> messages; // roomId → messages

  const RoomsState({this.joined = const [], this.messages = const {}});

  RoomsState withRoom(JoinedRoom room) {
    if (joined.any((r) => r.roomId == room.roomId)) return this;
    return RoomsState(
      joined: [...joined, room],
      messages: {...messages, room.roomId: messages[room.roomId] ?? []},
    );
  }

  RoomsState withoutRoom(String roomId) {
    return RoomsState(
      joined: joined.where((r) => r.roomId != roomId).toList(),
      messages: {...messages}..remove(roomId),
    );
  }

  RoomsState withMessage(String roomId, RoomMessage msg) {
    final current = messages[roomId] ?? [];
    return RoomsState(
      joined: joined,
      messages: {...messages, roomId: [...current, msg]},
    );
  }
}

class RoomsNotifier extends Notifier<RoomsState> {
  @override
  RoomsState build() => const RoomsState();

  /// Restore joined rooms + message history from the encrypted local store.
  void hydrate(List<JoinedRoom> joined, Map<String, List<RoomMessage>> messages) {
    state = RoomsState(joined: joined, messages: messages);
  }

  /// Derive key, subscribe to WS, update state. Throws on wrong password.
  /// [homeUrl] is non-empty when the private room is hosted on a federated
  /// peer; the join is then routed through the active server's S2S relay. The
  /// room key stays local and the sender travels inside the ciphertext, so the
  /// host only ever sees room_id + opaque payload.
  Future<void> joinRoom({
    required String roomId,
    required String roomName,
    required String saltHex,
    required String password,
    required WsClient ws,
    String homeUrl = '',
  }) async {
    final saltBytes = hexToBytes(saltHex);
    final derived = await deriveRoomKey(password, saltBytes);

    // Verify room_id matches derived key
    if (derived.roomId != roomId) {
      throw Exception('Wrong password or room ID mismatch');
    }

    _storeRoomKey(roomId, derived.roomKey);
    state = state.withRoom(JoinedRoom(
      roomId: roomId,
      roomName: roomName,
      saltHex: saltHex,
      homeUrl: homeUrl,
    ));

    ws.send({
      'type': 'room_join',
      'room_id': roomId,
      if (homeUrl.isNotEmpty) 'home': homeUrl,
      if (homeUrl.isNotEmpty) 'private': true,
    });
  }

  /// Join a public room (server-visible, not E2E — no password/key).
  /// [homeUrl] is non-empty when the room lives on a federated peer.
  void joinPublicRoom({
    required String roomId,
    required String roomName,
    required WsClient ws,
    String homeUrl = '',
  }) {
    state = state.withRoom(JoinedRoom(
      roomId: roomId,
      roomName: roomName,
      saltHex: '',
      isPublic: true,
      homeUrl: homeUrl,
    ));
    ws.send({
      'type': 'room_join',
      'room_id': roomId,
      if (homeUrl.isNotEmpty) 'home': homeUrl,
    });
  }

  /// Called when an admin kicked/banned us from a room.
  void kicked(String roomId) {
    _removeRoomKey(roomId);
    state = state.withoutRoom(roomId);
  }

  /// Re-subscribe to every joined room after a WS (re)connect. Room keys stay
  /// in memory, so no password re-entry is needed.
  void resendJoins(WsClient ws) {
    for (final room in state.joined) {
      ws.send({
        'type': 'room_join',
        'room_id': room.roomId,
        if (room.homeUrl.isNotEmpty) 'home': room.homeUrl,
        if (room.homeUrl.isNotEmpty && !room.isPublic) 'private': true,
      });
    }
  }

  void leaveRoom(String roomId, WsClient ws) {
    ws.send({'type': 'room_leave', 'room_id': roomId});
    _removeRoomKey(roomId);
    state = state.withoutRoom(roomId);
  }

  void addIncomingMessage(String roomId, RoomMessage msg) {
    state = state.withMessage(roomId, msg);
  }

  Future<void> sendRoomMessage({
    required String roomId,
    required String text,
    required String myUserId,
    required WsClient ws,
  }) async {
    final key = getRoomKey(roomId);
    final isPublic = state.joined.any((r) => r.roomId == roomId && r.isPublic);
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    if (key != null) {
      // Private room — E2E with the room key. The sender id travels inside the
      // ciphertext so federated hosts (which lack the key) never learn who is
      // talking; the outer `from` is stripped when the message is relayed.
      final inner = jsonEncode({'v': 1, 'from': myUserId, 'text': text});
      final encrypted = await encryptRoomMessage(inner, key);
      ws.send({'type': 'room_msg', 'room_id': roomId, 'nonce': 'enc', 'payload': encrypted, 'ts': ts});
    } else if (isPublic) {
      // Public room — plaintext (base64), server-visible.
      ws.send({'type': 'room_msg', 'room_id': roomId, 'nonce': 'plain', 'payload': base64Encode(utf8.encode(text)), 'ts': ts});
    } else {
      throw StateError('No key for room $roomId');
    }

    // Optimistic local insert
    state = state.withMessage(
      roomId,
      RoomMessage(
        id: '${myUserId}_${ts}_local',
        fromUserId: myUserId,
        text: text,
        timestamp: DateTime.fromMillisecondsSinceEpoch(ts * 1000),
        isOutgoing: true,
      ),
    );
  }
}

final roomsProvider = NotifierProvider<RoomsNotifier, RoomsState>(RoomsNotifier.new);

// ── Incoming room_msg handler (called from dispatchIncoming) ──────────────────

Future<void> dispatchRoomMsg(Map<String, dynamic> msg, WidgetRef ref) async {
  final roomId = msg['room_id'] as String? ?? '';
  final fromId = msg['from'] as String? ?? '';
  final payload = msg['payload'] as String? ?? '';
  final nonce = msg['nonce'] as String? ?? '';
  final ts = (msg['ts'] as int?) ?? 0;

  final key = getRoomKey(roomId);
  final isPublic = ref.read(roomsProvider).joined.any((r) => r.roomId == roomId && r.isPublic);
  if (key == null && !isPublic) return;

  final myUserId = ref.read(sessionProvider).identity?.userId ?? '';

  // Fetch display name if unknown
  if (fromId.isNotEmpty && fromId != myUserId) {
    final knownPeers = ref.read(knownPeersProvider);
    if (!knownPeers.containsKey(fromId)) {
      try {
        final data = await ref.read(apiClientProvider)?.getUser(fromId);
        if (data != null) {
          ref.read(knownPeersProvider.notifier).update((s) => {...s, fromId: data});
        }
      } catch (_) {}
    }
  }

  if (nonce == 'file_offer') {
    if (key == null) return; // file transfer is E2E (private rooms only)
    String decrypted;
    try {
      decrypted = await decryptRoomMessage(payload, key);
    } catch (_) {
      return;
    }
    try {
      final meta = jsonDecode(decrypted) as Map<String, dynamic>;
      final fileId = meta['file_id'] as String;
      final fileName = meta['name'] as String;
      final fileSize = meta['size'] as int;
      await ref.read(fileTransferProvider.notifier).onRoomFileOffer(
            roomId: roomId,
            fromId: fromId,
            fileId: fileId,
            fileName: fileName,
            fileSize: fileSize,
            myUserId: myUserId,
          );
    } catch (_) {}
    return;
  }

  if (nonce == 'file_chunk') {
    if (key == null) return; // file transfer is E2E (private rooms only)
    String decrypted;
    try {
      decrypted = await decryptRoomMessage(payload, key);
    } catch (_) {
      return;
    }
    try {
      final meta = jsonDecode(decrypted) as Map<String, dynamic>;
      final fileId = meta['file_id'] as String;
      final index = meta['index'] as int;
      final total = meta['total'] as int;
      final data = base64Decode(meta['data'] as String);
      await ref.read(fileTransferProvider.notifier).onRoomChunkReceived(
            fileId: fileId,
            chunkIndex: index,
            chunkTotal: total,
            chunkData: data,
          );
    } catch (_) {}
    return;
  }

  // Regular text message
  String text;
  var senderId = fromId;
  if (key != null) {
    String decrypted;
    try {
      decrypted = await decryptRoomMessage(payload, key);
    } catch (_) {
      decrypted = '';
      text = '[decryption failed]';
    }
    // New format: {v:1, from, text}. The sender inside the ciphertext is the
    // source of truth (the outer `from` is empty for federated private rooms).
    Map<String, dynamic>? inner;
    if (decrypted.isNotEmpty) {
      try {
        final m = jsonDecode(decrypted);
        if (m is Map<String, dynamic> && m['v'] == 1 && m.containsKey('text')) {
          inner = m;
        }
      } catch (_) {}
    }
    if (inner != null) {
      text = inner['text'] as String? ?? '';
      final innerFrom = inner['from'] as String? ?? '';
      if (innerFrom.isNotEmpty) senderId = innerFrom;
    } else if (decrypted.isNotEmpty) {
      text = decrypted; // legacy plain-text format
    } else {
      text = '[decryption failed]';
    }

    // The outer `from` was empty for a federated private room; resolve the
    // display name for the real sender we just recovered from the ciphertext.
    if (senderId.isNotEmpty && senderId != myUserId) {
      final knownPeers = ref.read(knownPeersProvider);
      if (!knownPeers.containsKey(senderId)) {
        try {
          final data = await ref.read(apiClientProvider)?.getUser(senderId);
          if (data != null) {
            ref.read(knownPeersProvider.notifier).update((s) => {...s, senderId: data});
          }
        } catch (_) {}
      }
    }
  } else {
    // Public room — plaintext (base64).
    try {
      text = utf8.decode(base64Decode(payload));
    } catch (_) {
      text = payload;
    }
  }

  ref.read(roomsProvider.notifier).addIncomingMessage(
    roomId,
    RoomMessage(
      id: '${senderId}_$ts',
      fromUserId: senderId,
      text: text,
      timestamp: ts > 0
          ? DateTime.fromMillisecondsSinceEpoch(ts * 1000)
          : DateTime.now(),
      isOutgoing: senderId == myUserId,
    ),
  );
}
