enum MessageStatus { sending, delivered, failed }

class ChatMessage {
  final String id;         // local UUID
  final String fromUserId;
  final String toUserId;
  final String text;
  final DateTime timestamp;
  final bool isOutgoing;
  final MessageStatus status;

  const ChatMessage({
    required this.id,
    required this.fromUserId,
    required this.toUserId,
    required this.text,
    required this.timestamp,
    required this.isOutgoing,
    this.status = MessageStatus.sending,
  });

  ChatMessage copyWith({MessageStatus? status}) => ChatMessage(
        id: id,
        fromUserId: fromUserId,
        toUserId: toUserId,
        text: text,
        timestamp: timestamp,
        isOutgoing: isOutgoing,
        status: status ?? this.status,
      );
}
