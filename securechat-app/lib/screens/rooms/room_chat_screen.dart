import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:securechat/models/room.dart';
import 'package:securechat/store/app_state.dart';
import 'package:securechat/store/file_transfer_store.dart';
import 'package:securechat/store/messages_store.dart';
import 'package:securechat/store/rooms_store.dart';
import 'package:securechat/store/voice_store.dart';
import 'package:securechat/widgets/emoji_input_bar.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

String _shortId(String userId) =>
    userId.length > 12 ? '${userId.substring(0, 12)}…' : userId;

class RoomChatScreen extends ConsumerStatefulWidget {
  final String roomId;
  final String roomName;

  const RoomChatScreen({
    super.key,
    required this.roomId,
    required this.roomName,
  });

  @override
  ConsumerState<RoomChatScreen> createState() => _RoomChatScreenState();
}

class _RoomChatScreenState extends ConsumerState<RoomChatScreen> {
  final _scrollCtrl = ScrollController();
  final _textCtrl = TextEditingController();

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();

    final myUserId = ref.read(sessionProvider).identity?.userId ?? '';
    final ws = ref.read(wsClientProvider);
    if (ws == null) return;

    try {
      await ref.read(roomsProvider.notifier).sendRoomMessage(
        roomId: widget.roomId,
        text: text,
        myUserId: myUserId,
        ws: ws,
      );
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Send failed: $e')));
      }
    }
  }

  Future<void> _sendFile() async {
    final myUserId = ref.read(sessionProvider).identity?.userId ?? '';
    final key = getRoomKey(widget.roomId);
    if (key == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Room key not available')));
      }
      return;
    }
    try {
      await ref.read(fileTransferProvider.notifier).sendRoomFile(
            roomId: widget.roomId,
            myUserId: myUserId,
            roomKey: key,
          );
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('File send failed: $e')));
      }
    }
  }

  void _showMembers() {
    final messages = ref.read(
      roomsProvider.select((s) => s.messages[widget.roomId] ?? []),
    );
    final myUserId = ref.read(sessionProvider).identity?.userId ?? '';
    final knownPeers = ref.read(knownPeersProvider);

    // Collect unique senders including self
    final members = <String>{myUserId, ...messages.map((m) => m.fromUserId)};

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Members (${members.length})',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: members.map((uid) {
                  final displayName =
                      knownPeers[uid]?['display_name'] as String? ?? '';
                  final isMe = uid == myUserId;
                  return ListTile(
                    leading: CircleAvatar(
                      child: Text(
                        displayName.isNotEmpty
                            ? displayName[0].toUpperCase()
                            : uid[0].toUpperCase(),
                      ),
                    ),
                    title: Text(
                      displayName.isNotEmpty
                          ? displayName
                          : _shortId(uid),
                    ),
                    subtitle: Text(
                      _shortId(uid),
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: isMe
                        ? const Chip(label: Text('You', style: TextStyle(fontSize: 11)))
                        : null,
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmLeave() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave Room?'),
        content: const Text('You will stop receiving messages from this room.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              final ws = ref.read(wsClientProvider);
              if (ws != null) {
                ref.read(roomsProvider.notifier).leaveRoom(widget.roomId, ws);
              }
              Navigator.of(context).pop();
            },
            child: const Text('Leave'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(
      roomsProvider.select((s) => s.messages[widget.roomId] ?? []),
    );
    final myUserId = ref.watch(sessionProvider).identity?.userId ?? '';

    // Scroll when new messages arrive
    ref.listen(
      roomsProvider.select((s) => s.messages[widget.roomId]?.length ?? 0),
      (_, __) => _scrollToBottom(),
    );

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.roomName),
            Text(
              '${widget.roomId.substring(0, 16)}...',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.people_outline),
            tooltip: 'Members',
            onPressed: _showMembers,
          ),
          IconButton(
            icon: const Icon(Icons.exit_to_app),
            tooltip: 'Leave room',
            onPressed: _confirmLeave,
          ),
        ],
      ),
      body: Column(
        children: [
          _VoiceBar(roomId: widget.roomId),
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Text('No messages yet', style: TextStyle(color: Colors.grey)),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (_, i) => _MessageBubble(
                      msg: messages[i],
                      isMe: messages[i].fromUserId == myUserId,
                    ),
                  ),
          ),
          EmojiInputBar(controller: _textCtrl, onSend: _send, onAttach: _sendFile),
        ],
      ),
    );
  }
}

class _MessageBubble extends ConsumerWidget {
  final RoomMessage msg;
  final bool isMe;
  const _MessageBubble({required this.msg, required this.isMe});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (msg.kind == RoomMessageKind.file) {
      return _RoomFileBubble(msg: msg, isMe: isMe);
    }

    final cs = Theme.of(context).colorScheme;
    final time = DateFormat('HH:mm').format(msg.timestamp);
    final knownPeers = ref.watch(knownPeersProvider);
    final senderName = knownPeers[msg.fromUserId]?['display_name'] as String?;
    final label = senderName ?? _shortId(msg.fromUserId);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isMe ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isMe)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                ),
              ),
            Text(msg.text),
            const SizedBox(height: 2),
            Text(
              time,
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoomFileBubble extends ConsumerWidget {
  final RoomMessage msg;
  final bool isMe;
  const _RoomFileBubble({required this.msg, required this.isMe});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final ft = ref.watch(fileTransferProvider.select((s) => s[msg.fileId ?? '']));

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: isMe ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.insert_drive_file, size: 20, color: cs.primary),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    msg.fileName ?? 'File',
                    style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurface),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (msg.fileSize != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(_formatSize(msg.fileSize!),
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ),
            if (ft != null) ...[
              const SizedBox(height: 8),
              _buildStatus(ft, cs),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatus(FileTransfer ft, ColorScheme cs) {
    return switch (ft.status) {
      FileTransferStatus.transferring => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: ft.progress, minHeight: 6),
            ),
            const SizedBox(height: 4),
            Text(
              '${(ft.progress * 100).toStringAsFixed(0)}%  (${ft.chunksReceived}/${ft.chunksTotal})',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      FileTransferStatus.done => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, size: 16, color: Colors.green),
            const SizedBox(width: 4),
            Text(
              ft.isOutgoing ? 'Sent' : 'Saved to ${ft.savedPath ?? "downloads"}',
              style: const TextStyle(fontSize: 12, color: Colors.green),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      FileTransferStatus.error => const Text('Error during transfer',
          style: TextStyle(fontSize: 12, color: Colors.red)),
      _ => const SizedBox.shrink(),
    };
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _VoiceBar extends ConsumerWidget {
  final String roomId;
  const _VoiceBar({required this.roomId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(voiceProvider);
    final cs = Theme.of(context).colorScheme;
    final isActive = voice.inCall && voice.activeRoomId == roomId;

    return Container(
      color: isActive ? cs.primaryContainer : cs.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(
            isActive ? Icons.mic : Icons.mic_none,
            size: 18,
            color: isActive ? cs.primary : cs.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isActive
                  ? '${voice.participants.length} in voice${voice.muted ? ' · Muted' : ''}'
                  : 'Voice channel',
              style: TextStyle(
                fontSize: 12,
                color: isActive ? cs.primary : cs.onSurfaceVariant,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          if (isActive) ...[
            IconButton(
              icon: Icon(voice.muted ? Icons.mic_off : Icons.mic, size: 20),
              tooltip: voice.muted ? 'Unmute' : 'Mute',
              onPressed: () => ref.read(voiceProvider.notifier).toggleMute(),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              icon: const Icon(Icons.call_end, size: 16),
              label: const Text('Leave', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                foregroundColor: cs.error,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              onPressed: () => ref.read(voiceProvider.notifier).leave(),
            ),
          ] else
            TextButton.icon(
              icon: const Icon(Icons.call, size: 16),
              label: const Text('Join', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              onPressed: () => ref.read(voiceProvider.notifier).join(roomId),
            ),
        ],
      ),
    );
  }
}

