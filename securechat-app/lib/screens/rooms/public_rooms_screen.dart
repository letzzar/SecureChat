import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:securechat/screens/rooms/room_chat_screen.dart';
import 'package:securechat/store/app_state.dart';
import 'package:securechat/store/messages_store.dart';
import 'package:securechat/store/rooms_store.dart';

/// Browse, search, create and join public (server-visible) rooms.
class PublicRoomsScreen extends ConsumerStatefulWidget {
  const PublicRoomsScreen({super.key});

  @override
  ConsumerState<PublicRoomsScreen> createState() => _PublicRoomsScreenState();
}

class _PublicRoomsScreenState extends ConsumerState<PublicRoomsScreen> {
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _rooms = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load(String q) async {
    final api = ref.read(apiClientProvider);
    if (api == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rooms = await api.searchPublicRooms(q);
      if (mounted) setState(() { _rooms = rooms; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; _loading = false; });
    }
  }

  void _remoteRoomInfo(String serverUrl) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Room on a federated server'),
        content: Text(
          'This room lives on $serverUrl. Joining rooms across servers is coming '
          'in a future update.\n\nYou can join it today by adding that server in '
          'Profile → Servers → Add server and switching to it.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _join(String roomId, String roomName) async {
    final api = ref.read(apiClientProvider);
    final ws = ref.read(wsClientProvider);
    if (api == null || ws == null) return;
    try {
      await api.joinPublicRoom(roomId);
      ref.read(roomsProvider.notifier).joinPublicRoom(roomId: roomId, roomName: roomName, ws: ws);
      if (!mounted) return;
      Navigator.of(context).pop();
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RoomChatScreen(roomId: roomId, roomName: roomName, isPublic: true),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _create() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New public room'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Room name', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final api = ref.read(apiClientProvider);
    if (api == null) return;
    try {
      final room = await api.createPublicRoom(name);
      await _join(room['room_id'] as String, room['room_name'] as String? ?? name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final joinedIds = ref.watch(roomsProvider).joined.map((r) => r.roomId).toSet();
    return Scaffold(
      appBar: AppBar(title: const Text('Public Rooms')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('Create'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search public rooms',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _load(_searchController.text.trim()),
                ),
              ),
              onSubmitted: (v) => _load(v.trim()),
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          Expanded(
            child: _rooms.isEmpty && !_loading
                ? const Center(child: Text('No public rooms', style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: _rooms.length,
                    itemBuilder: (_, i) {
                      final r = _rooms[i];
                      final id = r['room_id'] as String;
                      final name = r['room_name'] as String? ?? '';
                      final count = r['member_count'] as int? ?? 0;
                      final serverUrl = r['server_url'] as String? ?? '';
                      final isRemote = serverUrl.isNotEmpty;
                      final joined = joinedIds.contains(id);
                      return ListTile(
                        leading: CircleAvatar(child: Text(name.isNotEmpty ? name[0].toUpperCase() : '#')),
                        title: Row(
                          children: [
                            Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
                            if (isRemote) ...[
                              const SizedBox(width: 6),
                              Tooltip(
                                message: 'On $serverUrl',
                                child: Icon(Icons.hub_outlined,
                                    size: 14, color: Theme.of(context).colorScheme.primary),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Text(isRemote
                            ? '$count member${count == 1 ? '' : 's'} · ${Uri.tryParse(serverUrl)?.host ?? serverUrl}'
                            : '$count member${count == 1 ? '' : 's'}'),
                        trailing: isRemote
                            ? const Icon(Icons.chevron_right, color: Colors.grey)
                            : joined
                                ? const Text('Joined', style: TextStyle(color: Colors.grey))
                                : FilledButton(onPressed: () => _join(id, name), child: const Text('Join')),
                        onTap: isRemote
                            ? () => _remoteRoomInfo(serverUrl)
                            : joined
                                ? () {
                                    Navigator.of(context).pop();
                                    Navigator.of(context).push(MaterialPageRoute(
                                      builder: (_) => RoomChatScreen(roomId: id, roomName: name, isPublic: true),
                                    ));
                                  }
                                : () => _join(id, name),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
