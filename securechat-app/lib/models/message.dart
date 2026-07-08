enum MessageStatus { sending, delivered, failed }

enum MessageKind { text, file }

class ChatMessage {
  final String id;
  final String fromUserId;
  final String toUserId;
  final String text;
  final DateTime timestamp;
  final bool isOutgoing;
  final MessageStatus status;
  final MessageKind kind;
  final String? fileId;
  final String? fileName;
  final int? fileSize;

  const ChatMessage({
    required this.id,
    required this.fromUserId,
    required this.toUserId,
    this.text = '',
    required this.timestamp,
    required this.isOutgoing,
    this.status = MessageStatus.sending,
    this.kind = MessageKind.text,
    this.fileId,
    this.fileName,
    this.fileSize,
  });

  ChatMessage copyWith({MessageStatus? status}) => ChatMessage(
        id: id,
        fromUserId: fromUserId,
        toUserId: toUserId,
        text: text,
        timestamp: timestamp,
        isOutgoing: isOutgoing,
        status: status ?? this.status,
        kind: kind,
        fileId: fileId,
        fileName: fileName,
        fileSize: fileSize,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'from': fromUserId,
        'to': toUserId,
        'text': text,
        'ts': timestamp.millisecondsSinceEpoch,
        'out': isOutgoing,
        'status': status.index,
        'kind': kind.index,
        if (fileId != null) 'fileId': fileId,
        if (fileName != null) 'fileName': fileName,
        if (fileSize != null) 'fileSize': fileSize,
      };

  static ChatMessage fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        fromUserId: j['from'] as String,
        toUserId: j['to'] as String,
        text: j['text'] as String? ?? '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
        isOutgoing: j['out'] as bool? ?? false,
        status: MessageStatus.values[j['status'] as int? ?? 0],
        kind: MessageKind.values[j['kind'] as int? ?? 0],
        fileId: j['fileId'] as String?,
        fileName: j['fileName'] as String?,
        fileSize: j['fileSize'] as int?,
      );
}
