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

  /// Derive key, subscribe to WS, update state. Throws on wrong password.
  Future<void> joinRoom({
    required String roomId,
    required String roomName,
    required String saltHex,
    required String password,
    required WsClient ws,
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
    ));

    ws.send({'type': 'room_join', 'room_id': roomId});
  }

  /// Re-subscribe to every joined room after a WS (re)connect. Room keys stay
  /// in memory, so no password re-entry is needed.
  void resendJoins(WsClient ws) {
    for (final room in state.joined) {
      ws.send({'type': 'room_join', 'room_id': room.roomId});
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
    if (key == null) throw StateError('No key for room $roomId');

    final encrypted = await encryptRoomMessage(text, key);
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    ws.send({
      'type': 'room_msg',
      'room_id': roomId,
      'nonce': 'enc',
      'payload': encrypted,
      'ts': ts,
    });

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
  if (key == null) return;

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
  try {
    text = await decryptRoomMessage(payload, key);
  } catch (_) {
    text = '[decryption failed]';
  }

  ref.read(roomsProvider.notifier).addIncomingMessage(
    roomId,
    RoomMessage(
      id: '${fromId}_$ts',
      fromUserId: fromId,
      text: text,
      timestamp: ts > 0
          ? DateTime.fromMillisecondsSinceEpoch(ts * 1000)
          : DateTime.now(),
      isOutgoing: fromId == myUserId,
    ),
  );
}
