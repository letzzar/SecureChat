import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:securechat/crypto/identity.dart';
import 'package:securechat/crypto/room_crypto.dart';
import 'package:securechat/store/app_state.dart';
import 'package:securechat/store/messages_store.dart';
import 'package:securechat/store/rooms_store.dart';

class CreateRoomScreen extends ConsumerStatefulWidget {
  const CreateRoomScreen({super.key});

  @override
  ConsumerState<CreateRoomScreen> createState() => _CreateRoomScreenState();
}

class _CreateRoomScreenState extends ConsumerState<CreateRoomScreen> {
  final _nameCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _loading = false;
  _RoomInvite? _invite;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    try {
      // Generate random 16-byte salt
      final rng = Random.secure();
      final saltBytes = Uint8List(16);
      for (var i = 0; i < 16; i++) {
        saltBytes[i] = rng.nextInt(256);
      }
      final saltHex = bytesToHex(saltBytes);

      // Derive room key + room_id
      final derived = await deriveRoomKey(_passCtrl.text, saltBytes);

      // POST to server
      final api = ref.read(apiClientProvider);
      if (api == null) throw Exception('Not connected');

      await api.createRoom(
        roomId: derived.roomId,
        roomName: _nameCtrl.text.trim(),
        saltHex: saltHex,
      );

      // Join locally
      final ws = ref.read(wsClientProvider);
      if (ws == null) throw Exception('WebSocket not connected');

      await ref.read(roomsProvider.notifier).joinRoom(
        roomId: derived.roomId,
        roomName: _nameCtrl.text.trim(),
        saltHex: saltHex,
        password: _passCtrl.text,
        ws: ws,
      );

      setState(() {
        _invite = _RoomInvite(
          roomId: derived.roomId,
          roomName: _nameCtrl.text.trim(),
          saltHex: saltHex,
        );
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Room')),
      body: _invite != null ? _InviteView(invite: _invite!) : _FormView(
        formKey: _formKey,
        nameCtrl: _nameCtrl,
        passCtrl: _passCtrl,
        loading: _loading,
        onCreate: _create,
      ),
    );
  }
}

class _FormView extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController nameCtrl;
  final TextEditingController passCtrl;
  final bool loading;
  final VoidCallback onCreate;

  const _FormView({
    required this.formKey,
    required this.nameCtrl,
    required this.passCtrl,
    required this.loading,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'The room password is used to derive the encryption key. '
              'Share it out-of-band with members.',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Room name',
                border: OutlineInputBorder(),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: passCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Room password',
                border: OutlineInputBorder(),
              ),
              validator: (v) => (v == null || v.length < 8)
                  ? 'Minimum 8 characters'
                  : null,
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: loading ? null : onCreate,
              child: loading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Create Room'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoomInvite {
  final String roomId;
  final String roomName;
  final String saltHex;
  const _RoomInvite({
    required this.roomId,
    required this.roomName,
    required this.saltHex,
  });

  String toJson() => jsonEncode({
    'room_id': roomId,
    'room_name': roomName,
    'salt': saltHex,
  });
}

class _InviteView extends StatelessWidget {
  final _RoomInvite invite;
  const _InviteView({required this.invite});

  @override
  Widget build(BuildContext context) {
    final qrData = invite.toJson();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Room created! Share the QR code or the details below with members. '
            'They will need the room password separately.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 24),
          Center(
            child: QrImageView(
              data: qrData,
              version: QrVersions.auto,
              size: 220,
            ),
          ),
          const SizedBox(height: 24),
          _InfoTile(label: 'Room Name', value: invite.roomName),
          const SizedBox(height: 8),
          _InfoTile(label: 'Room ID', value: invite.roomId),
          const SizedBox(height: 8),
          _InfoTile(label: 'Salt', value: invite.saltHex),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Copy join details'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: qrData));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard')),
              );
            },
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final String label;
  final String value;
  const _InfoTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: SelectableText(
            value,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
      ],
    );
  }
}
