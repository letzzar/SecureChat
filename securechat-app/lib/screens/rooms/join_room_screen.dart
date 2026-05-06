import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:securechat/store/messages_store.dart';
import 'package:securechat/store/rooms_store.dart';

class JoinRoomScreen extends ConsumerStatefulWidget {
  const JoinRoomScreen({super.key});

  @override
  ConsumerState<JoinRoomScreen> createState() => _JoinRoomScreenState();
}

class _JoinRoomScreenState extends ConsumerState<JoinRoomScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _roomIdCtrl = TextEditingController();
  final _saltCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  bool _loading = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _roomIdCtrl.dispose();
    _saltCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _pasteJson() async {
    final data = await Clipboard.getData('text/plain');
    if (!mounted) return;
    if (data?.text == null) return;
    try {
      final json = jsonDecode(data!.text!) as Map<String, dynamic>;
      _nameCtrl.text = json['room_name'] as String? ?? '';
      _roomIdCtrl.text = json['room_id'] as String? ?? '';
      _saltCtrl.text = json['salt'] as String? ?? '';
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Details pasted')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Could not parse clipboard')));
      }
    }
  }

  Future<void> _join() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    try {
      final ws = ref.read(wsClientProvider);
      if (ws == null) throw Exception('WebSocket not connected');

      await ref.read(roomsProvider.notifier).joinRoom(
        roomId: _roomIdCtrl.text.trim(),
        roomName: _nameCtrl.text.trim(),
        saltHex: _saltCtrl.text.trim(),
        password: _passCtrl.text,
        ws: ws,
      );

      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join Room')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Paste the invite JSON from the room creator, or enter the details manually.',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.paste),
                label: const Text('Paste invite from clipboard'),
                onPressed: _pasteJson,
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Room name',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _roomIdCtrl,
                decoration: const InputDecoration(
                  labelText: 'Room ID (hex)',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _saltCtrl,
                decoration: const InputDecoration(
                  labelText: 'Salt (hex)',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Room password',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.length < 8) ? 'Min 8 characters' : null,
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: _loading ? null : _join,
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Join Room'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
