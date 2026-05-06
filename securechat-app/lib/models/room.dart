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

class RoomMessage {
  final String id;
  final String fromUserId;
  final String text;
  final DateTime timestamp;
  final bool isOutgoing;

  const RoomMessage({
    required this.id,
    required this.fromUserId,
    required this.text,
    required this.timestamp,
    required this.isOutgoing,
  });
}
