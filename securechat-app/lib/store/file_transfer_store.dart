import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:securechat/crypto/message_crypto.dart';
import 'package:securechat/crypto/noise_handshake.dart';
import 'package:securechat/crypto/room_crypto.dart';
import 'package:securechat/models/message.dart';
import 'package:securechat/models/room.dart';
import 'package:securechat/store/messages_store.dart';
import 'package:securechat/store/rooms_store.dart';

const _chunkSize = 32 * 1024; // 32 KB raw for DM
const _roomChunkSize = 20 * 1024; // 20 KB raw for rooms (double-encoded)

enum FileTransferStatus { offering, transferring, done, rejected, cancelled, error }

class FileTransfer {
  final String fileId;
  final String peerId;       // for DM: peer userId; for room: room id
  final String peerPubHex;  // empty for room transfers
  final String fileName;
  final int fileSize;
  final bool isOutgoing;
  final FileTransferStatus status;
  final int chunksReceived;
  final int chunksTotal;
  final List<Uint8List?> chunks;
  final String? savedPath;
  final bool isRoom;

  const FileTransfer({
    required this.fileId,
    required this.peerId,
    required this.peerPubHex,
    required this.fileName,
    required this.fileSize,
    required this.isOutgoing,
    required this.status,
    this.chunksReceived = 0,
    this.chunksTotal = 0,
    this.chunks = const [],
    this.savedPath,
    this.isRoom = false,
  });

  double get progress => chunksTotal > 0 ? chunksReceived / chunksTotal : 0.0;

  FileTransfer copyWith({
    FileTransferStatus? status,
    int? chunksReceived,
    int? chunksTotal,
    List<Uint8List?>? chunks,
    String? savedPath,
  }) =>
      FileTransfer(
        fileId: fileId,
        peerId: peerId,
        peerPubHex: peerPubHex,
        fileName: fileName,
        fileSize: fileSize,
        isOutgoing: isOutgoing,
        status: status ?? this.status,
        chunksReceived: chunksReceived ?? this.chunksReceived,
        chunksTotal: chunksTotal ?? this.chunksTotal,
        chunks: chunks ?? this.chunks,
        savedPath: savedPath ?? this.savedPath,
        isRoom: isRoom,
      );
}

class FileTransferNotifier extends Notifier<Map<String, FileTransfer>> {
  final _pendingBytes = <String, Uint8List>{};

  @override
  Map<String, FileTransfer> build() => {};

  void _put(FileTransfer ft) => state = {...state, ft.fileId: ft};

  void updateStatus(String fileId, FileTransferStatus status) {
    final ft = state[fileId];
    if (ft != null) state = {...state, fileId: ft.copyWith(status: status)};
  }

  Future<void> sendFile({
    required String myUserId,
    required String peerId,
    required String peerPubHex,
  }) async {
    final ws = ref.read(wsClientProvider);
    if (ws == null) throw StateError('Not connected');

    final sessionKey = getSession(peerPubHex);
    if (sessionKey == null) throw StateError('No session with peer — send a text message first');

    final result = await FilePicker.platform.pickFiles(withData: false);
    if (result == null || result.files.isEmpty) return;

    final picked = result.files.first;
    final fileName = picked.name;
    final fileSize = picked.size;

    Uint8List fileBytes;
    if (picked.bytes != null) {
      fileBytes = Uint8List.fromList(picked.bytes!);
    } else if (picked.path != null) {
      fileBytes = await File(picked.path!).readAsBytes();
    } else {
      throw StateError('Cannot read file data');
    }

    final fileId = _uuid();
    final totalChunks = (fileBytes.length / _chunkSize).ceil().clamp(1, 1 << 20);

    final metadata = jsonEncode({'name': fileName, 'size': fileSize});
    final enc = await encryptMessage(utf8.encode(metadata), sessionKey);

    _pendingBytes[fileId] = fileBytes;
    _put(FileTransfer(
      fileId: fileId,
      peerId: peerId,
      peerPubHex: peerPubHex,
      fileName: fileName,
      fileSize: fileSize,
      isOutgoing: true,
      status: FileTransferStatus.offering,
      chunksTotal: totalChunks,
    ));

    ref.read(conversationProvider.notifier).addMessage(
          peerId,
          ChatMessage(
            id: fileId,
            fromUserId: myUserId,
            toUserId: peerId,
            timestamp: DateTime.now(),
            isOutgoing: true,
            status: MessageStatus.sending,
            kind: MessageKind.file,
            fileId: fileId,
            fileName: fileName,
            fileSize: fileSize,
          ),
        );

    ws.send({
      'type': 'file_offer',
      'to': peerId,
      'file_id': fileId,
      'nonce': enc.nonce,
      'payload': enc.ciphertext,
      'sig': '',
      'e_pub': '',
    });
  }

  void onFileAccepted(String fileId, String peerId) {
    final ft = state[fileId];
    if (ft == null || !ft.isOutgoing) return;
    state = {...state, fileId: ft.copyWith(status: FileTransferStatus.transferring)};
    unawaited(_sendChunks(fileId, peerId));
  }

  Future<void> _sendChunks(String fileId, String peerId) async {
    final fileBytes = _pendingBytes.remove(fileId);
    if (fileBytes == null) return;

    final ft = state[fileId];
    if (ft == null) return;

    final sessionKey = getSession(ft.peerPubHex);
    if (sessionKey == null) return;

    final ws = ref.read(wsClientProvider);
    if (ws == null) return;

    final totalChunks = (fileBytes.length / _chunkSize).ceil().clamp(1, 1 << 20);

    try {
      for (var i = 0; i < totalChunks; i++) {
        if (state[fileId]?.status == FileTransferStatus.cancelled) return;

        final start = i * _chunkSize;
        final end = (start + _chunkSize).clamp(0, fileBytes.length);
        final enc = await encryptMessage(fileBytes.sublist(start, end), sessionKey);

        ws.send({
          'type': 'file_chunk',
          'to': peerId,
          'file_id': fileId,
          'chunk_index': i,
          'chunk_total': totalChunks,
          'nonce': enc.nonce,
          'payload': enc.ciphertext,
        });
      }

      final current = state[fileId];
      if (current != null && current.status == FileTransferStatus.transferring) {
        state = {...state, fileId: current.copyWith(status: FileTransferStatus.done)};
      }
    } catch (_) {
      updateStatus(fileId, FileTransferStatus.error);
    }
  }

  Future<void> onIncomingOffer({
    required String fileId,
    required String fromId,
    required String peerPubHex,
    required String fileName,
    required int fileSize,
    required String myUserId,
  }) async {
    final totalChunks = fileSize == 0 ? 1 : (fileSize / _chunkSize).ceil();
    _put(FileTransfer(
      fileId: fileId,
      peerId: fromId,
      peerPubHex: peerPubHex,
      fileName: fileName,
      fileSize: fileSize,
      isOutgoing: false,
      status: FileTransferStatus.offering,
      chunksTotal: totalChunks,
      chunks: List<Uint8List?>.filled(totalChunks, null, growable: true),
    ));

    ref.read(conversationProvider.notifier).addMessage(
          fromId,
          ChatMessage(
            id: fileId,
            fromUserId: fromId,
            toUserId: myUserId,
            timestamp: DateTime.now(),
            isOutgoing: false,
            status: MessageStatus.delivered,
            kind: MessageKind.file,
            fileId: fileId,
            fileName: fileName,
            fileSize: fileSize,
          ),
        );
  }

  void acceptOffer(String fileId) {
    final ft = state[fileId];
    if (ft == null) return;
    final ws = ref.read(wsClientProvider);
    if (ws == null) return;
    state = {...state, fileId: ft.copyWith(status: FileTransferStatus.transferring)};
    ws.send({'type': 'file_accept', 'to': ft.peerId, 'file_id': fileId});
  }

  void rejectOffer(String fileId) {
    final ft = state[fileId];
    if (ft == null) return;
    final ws = ref.read(wsClientProvider);
    if (ws == null) return;
    state = {...state, fileId: ft.copyWith(status: FileTransferStatus.rejected)};
    ws.send({'type': 'file_reject', 'to': ft.peerId, 'file_id': fileId});
  }

  Future<void> onChunkReceived({
    required String fileId,
    required int chunkIndex,
    required int chunkTotal,
    required List<int> decryptedChunk,
  }) async {
    var ft = state[fileId];
    if (ft == null || ft.isOutgoing) return;

    final chunks = List<Uint8List?>.from(ft.chunks);
    while (chunks.length <= chunkIndex) {
      chunks.add(null);
    }
    chunks[chunkIndex] = Uint8List.fromList(decryptedChunk);

    final received = chunks.where((c) => c != null).length;
    state = {
      ...state,
      fileId: ft.copyWith(
        status: FileTransferStatus.transferring,
        chunksReceived: received,
        chunksTotal: chunkTotal,
        chunks: chunks,
      ),
    };

    if (received == chunkTotal) {
      await _saveFile(fileId);
    }
  }

  Future<void> _saveFile(String fileId) async {
    final ft = state[fileId];
    if (ft == null) return;

    final allBytes = <int>[];
    for (final chunk in ft.chunks) {
      if (chunk != null) allBytes.addAll(chunk);
    }

    Directory? dir;
    try {
      dir = await getDownloadsDirectory();
    } catch (_) {}
    dir ??= await getApplicationDocumentsDirectory();

    final filePath = '${dir.path}${Platform.pathSeparator}${ft.fileName}';
    await File(filePath).writeAsBytes(allBytes);

    final ws = ref.read(wsClientProvider);
    ws?.send({'type': 'file_done', 'to': ft.peerId, 'file_id': fileId});

    state = {
      ...state,
      fileId: ft.copyWith(
        status: FileTransferStatus.done,
        savedPath: filePath,
        chunks: [],
      ),
    };
  }

  void onDone(String fileId) {
    final ft = state[fileId];
    if (ft != null && ft.isOutgoing) {
      state = {...state, fileId: ft.copyWith(status: FileTransferStatus.done)};
    }
  }

  // ── Room file transfer ──────────────────────────────────────────────────────

  Future<void> sendRoomFile({
    required String roomId,
    required String myUserId,
    required Uint8List roomKey,
  }) async {
    final ws = ref.read(wsClientProvider);
    if (ws == null) throw StateError('Not connected');

    final result = await FilePicker.platform.pickFiles(withData: false);
    if (result == null || result.files.isEmpty) return;

    final picked = result.files.first;
    final fileName = picked.name;
    final fileSize = picked.size;

    Uint8List fileBytes;
    if (picked.bytes != null) {
      fileBytes = Uint8List.fromList(picked.bytes!);
    } else if (picked.path != null) {
      fileBytes = await File(picked.path!).readAsBytes();
    } else {
      throw StateError('Cannot read file data');
    }

    final fileId = _uuid();
    final totalChunks = (fileBytes.length / _roomChunkSize).ceil().clamp(1, 1 << 20);

    _pendingBytes[fileId] = fileBytes;
    _put(FileTransfer(
      fileId: fileId,
      peerId: roomId,
      peerPubHex: '',
      fileName: fileName,
      fileSize: fileSize,
      isOutgoing: true,
      status: FileTransferStatus.transferring,
      chunksTotal: totalChunks,
      isRoom: true,
    ));

    ref.read(roomsProvider.notifier).addIncomingMessage(
          roomId,
          RoomMessage(
            id: fileId,
            fromUserId: myUserId,
            timestamp: DateTime.now(),
            isOutgoing: true,
            kind: RoomMessageKind.file,
            fileId: fileId,
            fileName: fileName,
            fileSize: fileSize,
          ),
        );

    // Send offer
    final offerJson = jsonEncode({'file_offer': true, 'file_id': fileId, 'name': fileName, 'size': fileSize});
    final encOffer = await encryptRoomMessage(offerJson, roomKey);
    ws.send({
      'type': 'room_msg',
      'room_id': roomId,
      'nonce': 'file_offer',
      'payload': encOffer,
    });

    unawaited(_sendRoomChunks(fileId, roomId, roomKey, fileBytes, totalChunks));
  }

  Future<void> _sendRoomChunks(
    String fileId,
    String roomId,
    Uint8List roomKey,
    Uint8List fileBytes,
    int totalChunks,
  ) async {
    _pendingBytes.remove(fileId);
    final ws = ref.read(wsClientProvider);
    if (ws == null) return;

    try {
      for (var i = 0; i < totalChunks; i++) {
        if (state[fileId]?.status == FileTransferStatus.cancelled) return;

        final start = i * _roomChunkSize;
        final end = (start + _roomChunkSize).clamp(0, fileBytes.length);
        final chunkData = base64Encode(fileBytes.sublist(start, end));
        final chunkJson = jsonEncode({
          'file_chunk': true,
          'file_id': fileId,
          'index': i,
          'total': totalChunks,
          'data': chunkData,
        });
        final encChunk = await encryptRoomMessage(chunkJson, roomKey);
        ws.send({
          'type': 'room_msg',
          'room_id': roomId,
          'nonce': 'file_chunk',
          'payload': encChunk,
        });
      }

      final ft = state[fileId];
      if (ft != null && ft.status == FileTransferStatus.transferring) {
        state = {...state, fileId: ft.copyWith(status: FileTransferStatus.done)};
      }
    } catch (_) {
      updateStatus(fileId, FileTransferStatus.error);
    }
  }

  Future<void> onRoomFileOffer({
    required String roomId,
    required String fromId,
    required String fileId,
    required String fileName,
    required int fileSize,
    required String myUserId,
  }) async {
    final totalChunks = fileSize == 0 ? 1 : (fileSize / _roomChunkSize).ceil();
    _put(FileTransfer(
      fileId: fileId,
      peerId: roomId,
      peerPubHex: '',
      fileName: fileName,
      fileSize: fileSize,
      isOutgoing: false,
      status: FileTransferStatus.transferring,
      chunksTotal: totalChunks,
      chunks: List<Uint8List?>.filled(totalChunks, null, growable: true),
      isRoom: true,
    ));

    ref.read(roomsProvider.notifier).addIncomingMessage(
          roomId,
          RoomMessage(
            id: fileId,
            fromUserId: fromId,
            timestamp: DateTime.now(),
            isOutgoing: false,
            kind: RoomMessageKind.file,
            fileId: fileId,
            fileName: fileName,
            fileSize: fileSize,
          ),
        );
  }

  Future<void> onRoomChunkReceived({
    required String fileId,
    required int chunkIndex,
    required int chunkTotal,
    required Uint8List chunkData,
  }) async {
    var ft = state[fileId];
    if (ft == null || ft.isOutgoing) return;

    final chunks = List<Uint8List?>.from(ft.chunks);
    while (chunks.length <= chunkIndex) {
      chunks.add(null);
    }
    chunks[chunkIndex] = chunkData;

    final received = chunks.where((c) => c != null).length;
    state = {
      ...state,
      fileId: ft.copyWith(
        status: FileTransferStatus.transferring,
        chunksReceived: received,
        chunksTotal: chunkTotal,
        chunks: chunks,
      ),
    };

    if (received == chunkTotal) {
      await _saveFile(fileId);
    }
  }
}

final fileTransferProvider =
    NotifierProvider<FileTransferNotifier, Map<String, FileTransfer>>(
        FileTransferNotifier.new);

String _uuid() {
  final b = Uint8List(16);
  final rng = Random.secure();
  for (var i = 0; i < 16; i++) {
    b[i] = rng.nextInt(256);
  }
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
      '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
