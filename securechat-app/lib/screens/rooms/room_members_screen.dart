import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:securechat/store/app_state.dart';

/// Member list of a public room with admin moderation (kick / ban / promote).
class RoomMembersScreen extends ConsumerStatefulWidget {
  final String roomId;
  final String roomName;
  const RoomMembersScreen({super.key, required this.roomId, required this.roomName});

  @override
  ConsumerState<RoomMembersScreen> createState() => _RoomMembersScreenState();
}

class _RoomMembersScreenState extends ConsumerState<RoomMembersScreen> {
  List<Map<String, dynamic>> _members = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(apiClientProvider);
    if (api == null) return;
    setState(() => _loading = true);
    try {
      final m = await api.roomMembers(widget.roomId);
      if (mounted) setState(() { _members = m; _loading = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _banDialog(String userId) async {
    final secs = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Ban duration'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 3600), child: const Text('1 hour')),
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 86400), child: const Text('1 day')),
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 604800), child: const Text('7 days')),
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 0), child: const Text('Permanent')),
        ],
      ),
    );
    if (secs == null) return;
    final api = ref.read(apiClientProvider);
    if (api != null) await _run(() => api.banMember(widget.roomId, userId, secs));
  }

  @override
  Widget build(BuildContext context) {
    final myId = ref.watch(sessionProvider).identity?.userId ?? '';
    final myRole = _members.firstWhere(
      (m) => m['user_id'] == myId,
      orElse: () => const {},
    )['role'] as String? ?? '';
    final amOwner = myRole == 'owner';
    final amAdmin = amOwner || myRole == 'admin';
    final api = ref.read(apiClientProvider);

    return Scaffold(
      appBar: AppBar(title: Text('${widget.roomName} · members')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _members.length,
              itemBuilder: (_, i) {
                final m = _members[i];
                final uid = m['user_id'] as String;
                final rawName = m['display_name'] as String? ?? '';
                final name = rawName.isNotEmpty ? rawName : uid.substring(0, 12);
                final role = m['role'] as String? ?? '';
                final isMe = uid == myId;
                final canModerate =
                    amAdmin && !isMe && role != 'owner' && (role != 'admin' || amOwner);

                return ListTile(
                  leading: CircleAvatar(child: Text(name[0].toUpperCase())),
                  title: Text(name),
                  subtitle: role.isNotEmpty ? Text(role) : null,
                  trailing: canModerate && api != null
                      ? PopupMenuButton<String>(
                          onSelected: (v) {
                            switch (v) {
                              case 'kick':
                                _run(() => api.kickMember(widget.roomId, uid));
                              case 'ban':
                                _banDialog(uid);
                              case 'promote':
                                _run(() => api.setRoomAdmin(widget.roomId, uid, true));
                              case 'demote':
                                _run(() => api.setRoomAdmin(widget.roomId, uid, false));
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'kick', child: Text('Kick')),
                            const PopupMenuItem(value: 'ban', child: Text('Ban…')),
                            if (role != 'admin') const PopupMenuItem(value: 'promote', child: Text('Make admin')),
                            if (role == 'admin' && amOwner)
                              const PopupMenuItem(value: 'demote', child: Text('Remove admin')),
                          ],
                        )
                      : null,
                );
              },
            ),
    );
  }
}
