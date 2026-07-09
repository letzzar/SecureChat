import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:securechat/crypto/identity.dart';
import 'package:securechat/models/message.dart';
import 'package:securechat/models/room.dart';
import 'package:securechat/screens/chat/chat_screen.dart';
import 'package:securechat/screens/rooms/create_room_screen.dart';
import 'package:securechat/screens/rooms/join_room_screen.dart';
import 'package:securechat/screens/rooms/public_rooms_screen.dart';
import 'package:securechat/screens/rooms/room_chat_screen.dart';
import 'package:securechat/store/app_state.dart';
import 'package:securechat/store/messages_store.dart';
import 'package:securechat/store/rooms_store.dart';

String _shortUserId(String id) => id.length > 16 ? '${id.substring(0, 16)}…' : id;

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    // Removing the last account returns to the setup screen.
    ref.listen(sessionProvider, (_, next) {
      if (next.identity == null && !next.isLoading) context.go('/setup');
    });

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
    final userId = user['user_id'] as String;
    // Store full peer data so conversation list shows display name
    ref.read(knownPeersProvider.notifier).update((s) => {...s, userId: user});
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          peerUserId: userId,
          peerDisplayName: user['display_name'] as String,
          peerStaticPubHex: user['public_key'] as String,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final conversations = ref.watch(conversationProvider).byPeer;
    final requests = ref.watch(contactRequestsProvider);

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
                final serverUrl = u['server_url'] as String? ?? '';
                final isFederated = serverUrl.isNotEmpty;
                return ListTile(
                  leading: CircleAvatar(
                    child: Text((u['display_name'] as String)[0].toUpperCase()),
                  ),
                  title: Row(
                    children: [
                      Text(u['display_name'] as String),
                      if (isFederated) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: serverUrl,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .secondaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              Uri.tryParse(serverUrl)?.host ?? serverUrl,
                              style: TextStyle(
                                fontSize: 10,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSecondaryContainer,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    '${(u['user_id'] as String).substring(0, 16)}...',
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () => _openChat(u),
                );
              },
            ),
          )
        else
          Expanded(
            child: Column(
              children: [
                if (requests.isNotEmpty) _ContactRequestsSection(requests: requests),
                if (conversations.isEmpty && requests.isEmpty)
                  const Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
                          SizedBox(height: 16),
                          Text('No conversations yet', style: TextStyle(color: Colors.grey)),
                          SizedBox(height: 8),
                          Text('Search a user above to start chatting',
                              style: TextStyle(color: Colors.grey, fontSize: 12)),
                        ],
                      ),
                    ),
                  )
                else if (conversations.isNotEmpty)
                  Expanded(child: _ConversationList(onTap: _openConversation)),
              ],
            ),
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

// ── Contact Requests Section ──────────────────────────────────────────────────

class _ContactRequestsSection extends ConsumerWidget {
  final List<ContactRequest> requests;
  const _ContactRequestsSection({required this.requests});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Contact Requests (${requests.length})',
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary),
          ),
        ),
        ...requests.map((r) => _ContactRequestTile(request: r)),
        const Divider(height: 1),
      ],
    );
  }
}

class _ContactRequestTile extends ConsumerWidget {
  final ContactRequest request;
  const _ContactRequestTile({required this.request});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = request.messages.isNotEmpty ? request.messages.last.text : '';
    return ListTile(
      leading: CircleAvatar(
        child: Text(request.displayName.isNotEmpty
            ? request.displayName[0].toUpperCase()
            : '?'),
      ),
      title: Text(request.displayName),
      subtitle: Text(
        request.messages.length > 1
            ? '${request.messages.length} messages — $preview'
            : preview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.tonal(
            onPressed: () => _accept(context, ref),
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
            child: const Text('Accept', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: () => _block(ref),
            style: TextButton.styleFrom(
                foregroundColor: Colors.red,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
            child: const Text('Block', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  void _accept(BuildContext context, WidgetRef ref) {
    ref.read(acceptedContactsProvider.notifier).update((s) => {...s, request.fromId});
    for (final msg in request.messages) {
      ref.read(conversationProvider.notifier).addMessage(request.fromId, msg);
    }
    ref.read(contactRequestsProvider.notifier).remove(request.fromId);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        peerUserId: request.fromId,
        peerDisplayName: request.displayName,
        peerStaticPubHex: request.pubHex,
      ),
    ));
  }

  void _block(WidgetRef ref) {
    ref.read(blockedUsersProvider.notifier).update((s) => {...s, request.fromId});
    ref.read(contactRequestsProvider.notifier).remove(request.fromId);
  }
}

// ── Conversation List ─────────────────────────────────────────────────────────

class _ConversationList extends ConsumerWidget {
  final void Function(String peerId) onTap;
  const _ConversationList({required this.onTap});

  void _showOptions(BuildContext context, WidgetRef ref, String peerId, String displayName) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(displayName,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete conversation'),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(conversationProvider.notifier).removeConversation(peerId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.block, color: Colors.red),
              title: const Text('Block user', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(blockedUsersProvider.notifier).update((s) => {...s, peerId});
                ref.read(acceptedContactsProvider.notifier).update((s) => {...s}..remove(peerId));
                ref.read(conversationProvider.notifier).removeConversation(peerId);
              },
            ),
          ],
        ),
      ),
    );
  }

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
        final displayName = knownPeers[peerId]?['display_name'] as String? ??
            _shortUserId(peerId);
        final unread = msgs
            .where((m) => !m.isOutgoing && m.status != MessageStatus.delivered)
            .length;

        return GestureDetector(
          onSecondaryTapDown: (_) =>
              _showOptions(context, ref, peerId, displayName),
          child: ListTile(
            leading: CircleAvatar(
                child: Text(displayName[0].toUpperCase())),
            title: Text(displayName),
            subtitle: lastMsg != null
                ? Text(
                    lastMsg.kind == MessageKind.file
                        ? (lastMsg.isOutgoing ? 'You: 📎 ${lastMsg.fileName ?? "File"}' : '📎 ${lastMsg.fileName ?? "File"}')
                        : (lastMsg.isOutgoing ? 'You: ${lastMsg.text}' : lastMsg.text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : null,
            trailing: unread > 0
                ? CircleAvatar(
                    radius: 10,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    child: Text('$unread',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 10)),
                  )
                : null,
            onTap: () => onTap(peerId),
            onLongPress: () =>
                _showOptions(context, ref, peerId, displayName),
          ),
        );
      },
    );
  }
}

// ── Rooms Tab (Public + Private) ──────────────────────────────────────────────

class _RoomsTab extends StatelessWidget {
  const _RoomsTab();

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(tabs: [Tab(text: 'Public Rooms'), Tab(text: 'Private Rooms')]),
          Expanded(
            child: TabBarView(children: [_PublicRoomsList(), _PrivateRoomsList()]),
          ),
        ],
      ),
    );
  }
}

class _PrivateRoomsList extends ConsumerWidget {
  const _PrivateRoomsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rooms = ref.watch(roomsProvider).joined.where((r) => !r.isPublic).toList();
    return Scaffold(
      body: rooms.isEmpty
          ? const _RoomsEmpty(text: 'No private rooms yet', hint: 'Create or join a room below')
          : _RoomListView(rooms: rooms),
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

class _PublicRoomsList extends ConsumerWidget {
  const _PublicRoomsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rooms = ref.watch(roomsProvider).joined.where((r) => r.isPublic).toList();
    return Scaffold(
      body: rooms.isEmpty
          ? const _RoomsEmpty(text: 'No public rooms joined', hint: 'Browse public rooms below')
          : _RoomListView(rooms: rooms),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'browse_public',
        icon: const Icon(Icons.travel_explore),
        label: const Text('Browse'),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PublicRoomsScreen()),
        ),
      ),
    );
  }
}

class _RoomListView extends ConsumerWidget {
  final List<JoinedRoom> rooms;
  const _RoomListView({required this.rooms});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.builder(
      itemCount: rooms.length,
      itemBuilder: (_, i) {
        final room = rooms[i];
        final msgs = ref.watch(roomsProvider.select((s) => s.messages[room.roomId] ?? []));
        final lastMsg = msgs.isNotEmpty ? msgs.last : null;
        return ListTile(
          leading: CircleAvatar(child: Text(room.roomName[0].toUpperCase())),
          title: Text(room.roomName),
          subtitle: lastMsg != null
              ? Text(lastMsg.isOutgoing ? 'You: ${lastMsg.text}' : lastMsg.text,
                  maxLines: 1, overflow: TextOverflow.ellipsis)
              : Text(room.isPublic ? 'Public room' : 'Private room',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => RoomChatScreen(
              roomId: room.roomId,
              roomName: room.roomName,
              isPublic: room.isPublic,
            ),
          )),
        );
      },
    );
  }
}

class _RoomsEmpty extends StatelessWidget {
  final String text;
  final String hint;
  const _RoomsEmpty({required this.text, required this.hint});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.group_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(text, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 8),
            Text(hint, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      );
}

// ── Profile Tab ───────────────────────────────────────────────────────────────

class _ProfileTab extends ConsumerWidget {
  const _ProfileTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(sessionProvider).identity;
    if (identity == null) return const SizedBox();
    final blockedUsers = ref.watch(blockedUsersProvider);
    final knownPeers = ref.watch(knownPeersProvider);
    final fedServers = ref.watch(federatedServersProvider);

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
        const SizedBox(height: 24),
        const Text('Servers', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          'Tap a server to switch. Each server is a separate identity.',
          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        ref.watch(accountsProvider).when(
              data: (accounts) => Column(
                children: [
                  ...accounts.map((a) {
                    final active = a.userId == identity.userId;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        color: active ? Theme.of(context).colorScheme.primary : null,
                      ),
                      title: Text(a.displayName.isNotEmpty ? a.displayName : _shortUserId(a.userId)),
                      subtitle: Text(
                        a.serverUrl,
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        tooltip: 'Edit server address',
                        onPressed: () => _editServerUrl(context, ref, a),
                      ),
                      onTap: active
                          ? null
                          : () => ref.read(sessionProvider.notifier).switchServer(a.userId),
                    );
                  }),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('Add server'),
                      onPressed: () => context.push('/setup'),
                    ),
                  ),
                ],
              ),
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(),
              ),
              error: (_, __) => const SizedBox(),
            ),
        const SizedBox(height: 16),
        const Text('Privacy', style: TextStyle(fontWeight: FontWeight.w600)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Block messages from unknown people'),
          subtitle: const Text('Only your accepted contacts can start a conversation.'),
          value: ref.watch(blockUnknownProvider),
          onChanged: (v) => ref.read(blockUnknownProvider.notifier).state = v,
        ),
        const SizedBox(height: 16),
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
        if (fedServers.isNotEmpty) ...[
          const SizedBox(height: 32),
          const Text('Federated Servers',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            'Your server is connected to these nodes. Messages are routed automatically.',
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          ...fedServers.map((s) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.hub_outlined),
                title: Text(s.name.isNotEmpty ? s.name : s.url),
                subtitle: Text(
                  Uri.tryParse(s.url)?.host ?? s.url,
                  style: const TextStyle(fontSize: 11),
                ),
              )),
        ],
        if (blockedUsers.isNotEmpty) ...[
          const SizedBox(height: 32),
          const Text('Blocked Users', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ...blockedUsers.map((uid) {
            final name = knownPeers[uid]?['display_name'] as String? ?? _shortUserId(uid);
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(child: Text(name[0].toUpperCase())),
              title: Text(name),
              subtitle: Text(_shortUserId(uid),
                  style: const TextStyle(fontSize: 11)),
              trailing: TextButton(
                onPressed: () => ref
                    .read(blockedUsersProvider.notifier)
                    .update((s) => {...s}..remove(uid)),
                child: const Text('Unblock'),
              ),
            );
          }),
        ],
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

  void _editServerUrl(BuildContext context, WidgetRef ref, AccountSummary account) {
    final controller = TextEditingController(text: account.serverUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit server address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Change the address of this server (e.g. http → https). Your identity on '
              'this server is kept.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Server address',
                hintText: 'https://chat.example.com',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final url = controller.text.trim().replaceAll(RegExp(r'/+$'), '');
              Navigator.pop(ctx);
              if (url.isNotEmpty) {
                ref.read(sessionProvider.notifier).updateServerUrl(account.userId, url);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _confirmLogout(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this server?'),
        content: const Text(
            'This deletes this server\'s identity and its local history on this device. '
            'Your other servers stay. Make sure you have exported the identity if you need it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(sessionProvider.notifier).logout();
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}
