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
}
