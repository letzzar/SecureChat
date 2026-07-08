// Wires the encrypted local store to the in-memory Riverpod state: hydrates
// history on startup and saves (debounced) whenever anything changes.
//
// Data is namespaced per account (by user_id), so this is already multi-server
// ready. Noise DM session keys are intentionally NOT persisted (forward
// secrecy) — only the decrypted message history is.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:securechat/crypto/identity.dart';
import 'package:securechat/models/message.dart';
import 'package:securechat/models/room.dart';
import 'package:securechat/store/app_state.dart';
import 'package:securechat/store/local_store.dart';
import 'package:securechat/store/messages_store.dart';
import 'package:securechat/store/rooms_store.dart';

class PersistenceController {
  final Ref _ref;
  Timer? _debounce;
  bool _ready = false;

  PersistenceController(this._ref);

  String? get _userId => _ref.read(sessionProvider).identity?.userId;
  String get _fileName => 'acct_${_userId ?? 'none'}.json';

  /// Load the active account's history and hydrate the providers. Call once at
  /// startup, before the UI reads the state.
  Future<void> hydrate() async {
    if (_userId == null) return;
    final data = await loadEncrypted(_fileName);
    if (data != null) {
      final conv = <String, List<ChatMessage>>{};
      (data['conversations'] as Map<String, dynamic>? ?? {}).forEach((peer, list) {
        conv[peer] = (list as List)
            .map((m) => ChatMessage.fromJson((m as Map).cast<String, dynamic>()))
            .toList();
      });
      _ref.read(conversationProvider.notifier).hydrate(conv);

      final joined = ((data['rooms'] as List?) ?? [])
          .map((r) => JoinedRoom.fromJson((r as Map).cast<String, dynamic>()))
          .toList();
      final roomMsgs = <String, List<RoomMessage>>{};
      (data['roomMessages'] as Map<String, dynamic>? ?? {}).forEach((rid, list) {
        roomMsgs[rid] = (list as List)
            .map((m) => RoomMessage.fromJson((m as Map).cast<String, dynamic>()))
            .toList();
      });
      _ref.read(roomsProvider.notifier).hydrate(joined, roomMsgs);

      final keys = <String, Uint8List>{};
      (data['roomKeys'] as Map<String, dynamic>? ?? {}).forEach((rid, hex) {
        keys[rid] = hexToBytes(hex as String);
      });
      restoreRoomKeys(keys);

      _ref.read(knownPeersProvider.notifier).state =
          (data['knownPeers'] as Map<String, dynamic>? ?? {})
              .map((k, v) => MapEntry(k, (v as Map).cast<String, dynamic>()));
      _ref.read(acceptedContactsProvider.notifier).state =
          ((data['accepted'] as List?) ?? []).cast<String>().toSet();
      _ref.read(blockedUsersProvider.notifier).state =
          ((data['blocked'] as List?) ?? []).cast<String>().toSet();
      _ref.read(contactRequestsProvider.notifier).hydrate(
            ((data['contactRequests'] as List?) ?? []).map((r) {
              final m = (r as Map).cast<String, dynamic>();
              return ContactRequest(
                fromId: m['fromId'] as String,
                displayName: m['displayName'] as String? ?? '',
                pubHex: m['pubHex'] as String? ?? '',
                messages: ((m['messages'] as List?) ?? [])
                    .map((x) => ChatMessage.fromJson((x as Map).cast<String, dynamic>()))
                    .toList(),
              );
            }).toList(),
          );
    }
    _ready = true;
  }

  /// Schedules a debounced save. Wired to every relevant provider.
  void scheduleSave() {
    if (!_ready) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _save);
  }

  Future<void> _save() async {
    if (_userId == null) return;
    final rooms = _ref.read(roomsProvider);
    final data = <String, dynamic>{
      'conversations': _ref.read(conversationProvider).byPeer.map(
            (peer, list) => MapEntry(peer, list.map((m) => m.toJson()).toList()),
          ),
      'rooms': rooms.joined.map((r) => r.toJson()).toList(),
      'roomMessages':
          rooms.messages.map((rid, list) => MapEntry(rid, list.map((m) => m.toJson()).toList())),
      'roomKeys': exportRoomKeys().map((rid, k) => MapEntry(rid, bytesToHex(k))),
      'knownPeers': _ref.read(knownPeersProvider),
      'accepted': _ref.read(acceptedContactsProvider).toList(),
      'blocked': _ref.read(blockedUsersProvider).toList(),
      'contactRequests': _ref.read(contactRequestsProvider).map((r) => {
            'fromId': r.fromId,
            'displayName': r.displayName,
            'pubHex': r.pubHex,
            'messages': r.messages.map((m) => m.toJson()).toList(),
          }).toList(),
    };
    await saveEncrypted(_fileName, data);
  }
}

final persistenceProvider = Provider<PersistenceController>((ref) {
  final c = PersistenceController(ref);
  ref.listen(conversationProvider, (_, __) => c.scheduleSave());
  ref.listen(roomsProvider, (_, __) => c.scheduleSave());
  ref.listen(knownPeersProvider, (_, __) => c.scheduleSave());
  ref.listen(acceptedContactsProvider, (_, __) => c.scheduleSave());
  ref.listen(blockedUsersProvider, (_, __) => c.scheduleSave());
  ref.listen(contactRequestsProvider, (_, __) => c.scheduleSave());
  return c;
});
