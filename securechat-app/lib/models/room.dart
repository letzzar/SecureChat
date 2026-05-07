class JoinedRoom {
  final String roomId;
  final String roomName;
  final String saltHex;

  const JoinedRoom({
    required this.roomId,
    required this.roomName,
    required this.saltHex,
  });
}

enum RoomMessageKind { text, file }

class RoomMessage {
  final String id;
  final String fromUserId;
  final String text;
  final DateTime timestamp;
  final bool isOutgoing;
  final RoomMessageKind kind;
  final String? fileId;
  final String? fileName;
  final int? fileSize;

  const RoomMessage({
    required this.id,
    required this.fromUserId,
    this.text = '',
    required this.timestamp,
    required this.isOutgoing,
    this.kind = RoomMessageKind.text,
    this.fileId,
    this.fileName,
    this.fileSize,
  });
}
