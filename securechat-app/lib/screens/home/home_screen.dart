import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:securechat/models/message.dart';
import 'package:securechat/screens/chat/chat_screen.dart';
import 'package:securechat/screens/rooms/create_room_screen.dart';
import 'package:securechat/screens/rooms/join_room_screen.dart';
import 'package:securechat/screens/rooms/room_chat_screen.dart';
import 'package:securechat/store/app_state.dart';
import 'package:securechat/store/messages_store.dart';
import 'package:securechat/store/rooms_store.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(sessionProvider).identity;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SecureChat'),
        actions: [
          if (identity != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  identity.displayName,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: const [
          _DirectMessagesTab(),
          _RoomsTab(),
          _ProfileTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Chats'),
          NavigationDestination(icon: Icon(Icons.group_outlined), label: 'Rooms'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Profile'),
        ],
      ),
    );
  }
}

// ── Direct Messages Tab ───────────────────────────────────────────────────────

class _DirectMessagesTab extends ConsumerStatefulWidget {
  const _DirectMessagesTab();

  @override
  ConsumerState<_DirectMessagesTab> createState() => _DirectMessagesTabState();
}

class _DirectMessagesTabState extends ConsumerState<_DirectMessagesTab> {
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _searching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final results = await ref.read(apiClientProvider)?.searchUsers(q) ?? [];
      final myId = ref.read(sessionProvider).identity?.userId ?? '';
      setState(() {
        _searchResults = results.where((u) => u['user_id'] != myId).toList();
      });
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _openChat(Map<String, dynamic> user) {
    _searchController.clear();
    setState(() => _searchResults = []);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          peerUserId: user['user_id'] as String,
          peerDisplayName: user['display_name'] as String,
          peerStaticPubHex: user['public_key'] as String,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final conversations = ref.watch(conversationProvider).byPeer;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search users...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onChanged: _search,
          ),
        ),
        if (_searchResults.isNotEmpty)
          Expanded(
            child: ListView.builder(
              itemCount: _searchResults.length,
              itemBuilder: (_, i) {
                final u = _searchResults[i];
                return ListTile(
                  leading: CircleAvatar(
                    child: Text((u['display_name'] as String)[0].toUpperCase()),
                  ),
                  title: Text(u['display_name'] as String),
                  subtitle: Text(
                    '${(u['user_id'] as String).substring(0, 16)}...',
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () => _openChat(u),
                );
              },
            ),
          )
        else if (conversations.isEmpty)
          const Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('No conversations yet', style: TextStyle(color: Colors.grey)),
                  SizedBox(height: 8),
                  Text('Search a user above to start chatting', style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: _ConversationList(onTap: _openConversation),
          ),
      ],
    );
  }

  Future<void> _openConversation(String peerId) async {
    var peer = ref.read(knownPeersProvider)[peerId];
    if (peer == null) {
      try {
        final data = await ref.read(apiClientProvider)?.getUser(peerId);
        if (data != null) {
          ref.read(knownPeersProvider.notifier).update((s) => {...s, peerId: data});
          peer = data;
        }
      } catch (_) {}
    }
    if (peer == null || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          peerUserId: peerId,
          peerDisplayName: peer!['display_name'] as String? ?? peerId,
          peerStaticPubHex: peer['public_key'] as String? ?? '',
        ),
      ),
    );
  }
}

class _ConversationList extends ConsumerWidget {
  final void Function(String peerId) onTap;
  const _ConversationList({required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(conversationProvider).byPeer;
    final knownPeers = ref.watch(knownPeersProvider);

    final peers = conversations.keys.toList();

    return ListView.builder(
      itemCount: peers.length,
      itemBuilder: (_, i) {
        final peerId = peers[i];
        final msgs = conversations[peerId] ?? [];
        final lastMsg = msgs.isNotEmpty ? msgs.last : null;
        final displayName = knownPeers[peerId]?['display_name'] as String? ?? peerId;
        final unread = msgs.where((m) => !m.isOutgoing && m.status != MessageStatus.delivered).length;

        return ListTile(
          leading: CircleAvatar(child: Text(displayName[0].toUpperCase())),
          title: Text(displayName),
          subtitle: lastMsg != null
              ? Text(
                  lastMsg.isOutgoing ? 'You: ${lastMsg.text}' : lastMsg.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : null,
          trailing: unread > 0
              ? CircleAvatar(
                  radius: 10,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 10)),
                )
              : null,
          onTap: () => onTap(peerId),
        );
      },
    );
  }
}

// ── Rooms Tab ─────────────────────────────────────────────────────────────────

class _RoomsTab extends ConsumerWidget {
  const _RoomsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final joined = ref.watch(roomsProvider).joined;

    return Scaffold(
      body: joined.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.group_outlined, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('No rooms joined yet', style: TextStyle(color: Colors.grey)),
                  SizedBox(height: 8),
                  Text('Create or join a room below', style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            )
          : ListView.builder(
              itemCount: joined.length,
              itemBuilder: (_, i) {
                final room = joined[i];
                final msgs = ref.watch(
                  roomsProvider.select((s) => s.messages[room.roomId] ?? []),
                );
                final lastMsg = msgs.isNotEmpty ? msgs.last : null;

                return ListTile(
                  leading: CircleAvatar(
                    child: Text(room.roomName[0].toUpperCase()),
                  ),
                  title: Text(room.roomName),
                  subtitle: lastMsg != null
                      ? Text(
                          lastMsg.isOutgoing ? 'You: ${lastMsg.text}' : lastMsg.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : Text(
                          '${room.roomId.substring(0, 16)}...',
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => RoomChatScreen(
                        roomId: room.roomId,
                        roomName: room.roomName,
                      ),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'join_room',
            tooltip: 'Join room',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const JoinRoomScreen()),
            ),
            child: const Icon(Icons.login),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: 'create_room',
            tooltip: 'Create room',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CreateRoomScreen()),
            ),
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

// ── Profile Tab ───────────────────────────────────────────────────────────────

class _ProfileTab extends ConsumerWidget {
  const _ProfileTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(sessionProvider).identity;
    if (identity == null) return const SizedBox();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 16),
        CircleAvatar(
          radius: 40,
          child: Text(
            identity.displayName.isNotEmpty ? identity.displayName[0].toUpperCase() : '?',
            style: const TextStyle(fontSize: 32),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          identity.displayName,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 32),
        const Text('Your identity (User ID)', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            identity.userId,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
        const SizedBox(height: 16),
        const Text('Server', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(identity.serverUrl, style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 32),
        FilledButton.icon(
          icon: const Icon(Icons.person_add_outlined),
          label: const Text('Generate invite code'),
          onPressed: () => _generateInvite(context, ref),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.logout, color: Colors.red),
          label: const Text('Log out', style: TextStyle(color: Colors.red)),
          onPressed: () => _confirmLogout(context, ref),
        ),
      ],
    );
  }

  void _generateInvite(BuildContext context, WidgetRef ref) async {
    final api = ref.read(apiClientProvider);
    if (api == null) return;

    try {
      final result = await api.createInvite();
      final token = result['token'] as String? ?? '';
      if (!context.mounted) return;

      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Invite Code'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Share this code with the person you want to invite. It expires in 48 hours and can only be used once.',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              SelectableText(
                token,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: token));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Invite code copied')),
                );
              },
              child: const Text('Copy & Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _confirmLogout(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('This will delete your local identity. Make sure you have exported it first.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(sessionProvider.notifier).logout();
            },
            child: const Text('Log out'),
          ),
        ],
      ),
    );
  }
}
