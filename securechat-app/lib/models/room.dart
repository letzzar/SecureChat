class JoinedRoom {
  final String roomId;
  final String roomName;
  final String saltHex;

  const JoinedRoom({
    required this.roomId,
    required this.roomName,
    required this.saltHex,
  });

  Map<String, dynamic> toJson() =>
      {'roomId': roomId, 'roomName': roomName, 'saltHex': saltHex};

  static JoinedRoom fromJson(Map<String, dynamic> j) => JoinedRoom(
        roomId: j['roomId'] as String,
        roomName: j['roomName'] as String,
        saltHex: j['saltHex'] as String,
      );
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'from': fromUserId,
        'text': text,
        'ts': timestamp.millisecondsSinceEpoch,
        'out': isOutgoing,
        'kind': kind.index,
        if (fileId != null) 'fileId': fileId,
        if (fileName != null) 'fileName': fileName,
        if (fileSize != null) 'fileSize': fileSize,
      };

  static RoomMessage fromJson(Map<String, dynamic> j) => RoomMessage(
        id: j['id'] as String,
        fromUserId: j['from'] as String,
        text: j['text'] as String? ?? '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
        isOutgoing: j['out'] as bool? ?? false,
        kind: RoomMessageKind.values[j['kind'] as int? ?? 0],
        fileId: j['fileId'] as String?,
        fileName: j['fileName'] as String?,
        fileSize: j['fileSize'] as int?,
      );
}
