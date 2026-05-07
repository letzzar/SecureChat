import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:securechat/models/message.dart';
import 'package:securechat/store/app_state.dart';
import 'package:securechat/store/file_transfer_store.dart';
import 'package:securechat/store/messages_store.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String peerUserId;
  final String peerDisplayName;
  final String peerStaticPubHex;

  const ChatScreen({
    super.key,
    required this.peerUserId,
    required this.peerDisplayName,
    required this.peerStaticPubHex,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending) return;

    final identity = ref.read(sessionProvider).identity;
    if (identity == null) return;

    setState(() {
      _sending = true;
      _error = null;
    });
    _inputController.clear();

    try {
      await sendDM(
        ref: ref,
        myUserId: identity.userId,
        peerUserId: widget.peerUserId,
        peerStaticPubHex: widget.peerStaticPubHex,
        text: text,
      );
      _scrollToBottom();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendFile() async {
    final identity = ref.read(sessionProvider).identity;
    if (identity == null) return;

    setState(() => _error = null);
    try {
      await ref.read(fileTransferProvider.notifier).sendFile(
            myUserId: identity.userId,
            peerId: widget.peerUserId,
            peerPubHex: widget.peerStaticPubHex,
          );
      _scrollToBottom();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(conversationProvider).byPeer[widget.peerUserId] ?? [];
    final identity = ref.watch(sessionProvider).identity;
    final colorScheme = Theme.of(context).colorScheme;

    ref.listen(conversationProvider, (_, __) => _scrollToBottom());

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.peerDisplayName, style: const TextStyle(fontSize: 16)),
            Text(
              '${widget.peerUserId.substring(0, 8)}...',
              style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Text(
                      'No messages yet.\nSend one to start a secure conversation.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (ctx, i) => _MessageBubble(
                      message: messages[i],
                      myUserId: identity?.userId ?? '',
                    ),
                  ),
          ),
          if (_error != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              color: colorScheme.errorContainer,
              child: Text(_error!,
                  style: TextStyle(color: colorScheme.onErrorContainer, fontSize: 12)),
            ),
          _InputBar(
            controller: _inputController,
            sending: _sending,
            onSend: _send,
            onAttach: _sendFile,
          ),
        ],
      ),
    );
  }
}

// ── Message bubble (text or file) ─────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final String myUserId;

  const _MessageBubble({required this.message, required this.myUserId});

  @override
  Widget build(BuildContext context) {
    if (message.kind == MessageKind.file) {
      return _FileBubble(message: message);
    }

    final isMe = message.isOutgoing;
    final colorScheme = Theme.of(context).colorScheme;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        decoration: BoxDecoration(
          color: isMe ? colorScheme.primary : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              message.text,
              style: TextStyle(
                color: isMe ? colorScheme.onPrimary : colorScheme.onSurface,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTime(message.timestamp),
                  style: TextStyle(
                    fontSize: 10,
                    color: isMe
                        ? colorScheme.onPrimary.withValues(alpha: 0.7)
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  Icon(
                    _statusIcon(message.status),
                    size: 12,
                    color: colorScheme.onPrimary.withValues(alpha: 0.7),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  IconData _statusIcon(MessageStatus status) => switch (status) {
        MessageStatus.sending => Icons.access_time,
        MessageStatus.delivered => Icons.done_all,
        MessageStatus.failed => Icons.error_outline,
      };
}

// ── File bubble ───────────────────────────────────────────────────────────────

class _FileBubble extends ConsumerWidget {
  final ChatMessage message;
  const _FileBubble({required this.message});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fileId = message.fileId ?? '';
    final ft = ref.watch(fileTransferProvider.select((s) => s[fileId]));
    final isMe = message.isOutgoing;
    final cs = Theme.of(context).colorScheme;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
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
                    message.fileName ?? 'File',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (message.fileSize != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  _formatSize(message.fileSize!),
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ),
            if (ft != null) ...[
              const SizedBox(height: 8),
              _FileStatus(ft: ft, ref: ref),
            ],
          ],
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _FileStatus extends StatelessWidget {
  final FileTransfer ft;
  final WidgetRef ref;
  const _FileStatus({required this.ft, required this.ref});

  @override
  Widget build(BuildContext context) {
    return switch (ft.status) {
      FileTransferStatus.offering when !ft.isOutgoing => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.tonal(
              onPressed: () =>
                  ref.read(fileTransferProvider.notifier).acceptOffer(ft.fileId),
              style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
              child: const Text('Accept', style: TextStyle(fontSize: 13)),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () =>
                  ref.read(fileTransferProvider.notifier).rejectOffer(ft.fileId),
              style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
              child:
                  const Text('Reject', style: TextStyle(fontSize: 13, color: Colors.red)),
            ),
          ],
        ),
      FileTransferStatus.offering => const Text(
          'Waiting for acceptance…',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      FileTransferStatus.transferring => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: ft.progress,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${(ft.progress * 100).toStringAsFixed(0)}%  '
              '(${ft.chunksReceived}/${ft.chunksTotal} parts)',
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
      FileTransferStatus.rejected => const Text(
          'Rejected',
          style: TextStyle(fontSize: 12, color: Colors.red),
        ),
      FileTransferStatus.cancelled => const Text(
          'Cancelled',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      FileTransferStatus.error => const Text(
          'Error during transfer',
          style: TextStyle(fontSize: 12, color: Colors.red),
        ),
    };
  }
}

// ── Input bar ─────────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  const _InputBar({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onAttach,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.attach_file),
              tooltip: 'Send file',
              onPressed: onAttach,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: 'Message',
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: sending ? null : onSend,
              icon: sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
