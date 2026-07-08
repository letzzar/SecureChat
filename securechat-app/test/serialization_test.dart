import 'package:flutter_test/flutter_test.dart';
import 'package:securechat/models/message.dart';
import 'package:securechat/models/room.dart';

void main() {
  test('ChatMessage JSON round-trip preserves all fields', () {
    final m = ChatMessage(
      id: 'abc',
      fromUserId: 'u1',
      toUserId: 'u2',
      text: 'hola 👋',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1714900000000),
      isOutgoing: true,
      status: MessageStatus.delivered,
      kind: MessageKind.file,
      fileId: 'f1',
      fileName: 'foto.jpg',
      fileSize: 1234,
    );
    final r = ChatMessage.fromJson(m.toJson());
    expect(r.id, m.id);
    expect(r.fromUserId, m.fromUserId);
    expect(r.toUserId, m.toUserId);
    expect(r.text, m.text);
    expect(r.timestamp, m.timestamp);
    expect(r.isOutgoing, m.isOutgoing);
    expect(r.status, m.status);
    expect(r.kind, m.kind);
    expect(r.fileId, m.fileId);
    expect(r.fileName, m.fileName);
    expect(r.fileSize, m.fileSize);
  });

  test('RoomMessage JSON round-trip preserves all fields', () {
    final m = RoomMessage(
      id: 'rm1',
      fromUserId: 'u1',
      text: 'sala',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1714900001000),
      isOutgoing: false,
      kind: RoomMessageKind.text,
    );
    final r = RoomMessage.fromJson(m.toJson());
    expect(r.id, m.id);
    expect(r.fromUserId, m.fromUserId);
    expect(r.text, m.text);
    expect(r.timestamp, m.timestamp);
    expect(r.isOutgoing, m.isOutgoing);
    expect(r.kind, m.kind);
  });

  test('JoinedRoom JSON round-trip', () {
    const j = JoinedRoom(roomId: 'r1', roomName: 'equipo', saltHex: 'aabb');
    final r = JoinedRoom.fromJson(j.toJson());
    expect(r.roomId, j.roomId);
    expect(r.roomName, j.roomName);
    expect(r.saltHex, j.saltHex);
  });
}
