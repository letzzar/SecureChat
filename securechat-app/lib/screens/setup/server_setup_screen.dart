import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:securechat/crypto/identity.dart';
import 'package:securechat/network/api_client.dart';
import 'package:securechat/store/app_state.dart';
import 'package:securechat/store/persistence.dart';

class ServerSetupScreen extends ConsumerStatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  ConsumerState<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends ConsumerState<ServerSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController(text: 'https://');
  final _portController = TextEditingController(text: '8443');
  final _nameController = TextEditingController();
  final _inviteController = TextEditingController();
  bool _specifyPort = false;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    _portController.dispose();
    _nameController.dispose();
    _inviteController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    // Combine the address (scheme + host, https by default) with the separate
    // port field into the final server URL.
    final addr = _urlController.text.trim();
    final parsed = Uri.tryParse(addr);
    final scheme = (parsed != null && parsed.hasScheme) ? parsed.scheme : 'https';
    final host = (parsed != null && parsed.host.isNotEmpty)
        ? parsed.host
        : addr.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '').split('/').first.split(':').first;
    final port = _specifyPort ? (int.tryParse(_portController.text.trim()) ?? 8443) : 8443;
    final serverUrl = '$scheme://$host:$port';
    final displayName = _nameController.text.trim();

    try {
      final client = ApiClient(serverUrl);

      // Step 1: verify server is reachable
      await client.checkHealth();

      // Step 2: generate key pairs and register in one go
      final identity = await generateAndSaveIdentity(
        displayName: displayName,
        serverUrl: serverUrl,
        jwt: '', // temporary — will be replaced after register
      );

      // Step 3: register on server, get JWT
      final jwt = await client.register(
        userId: identity.userId,
        displayName: displayName,
        publicKey: bytesToHex(identity.x25519Public),
        signPublic: bytesToHex(identity.ed25519Public),
        inviteCode: _inviteController.text.trim().replaceAll('-', ''),
      );

      // Step 4: persist the real JWT
      await saveJwt(jwt);

      // Step 5: build final identity from already-available data (avoids
      // a read-after-write race on Windows Credential Manager)
      final finalIdentity = LocalIdentity(
        userId: identity.userId,
        displayName: identity.displayName,
        serverUrl: identity.serverUrl,
        jwt: jwt,
        x25519Public: identity.x25519Public,
        ed25519Public: identity.ed25519Public,
      );
      await ref.read(sessionProvider.notifier).setIdentity(finalIdentity);
      // Start/switch persistence for this (new, empty) account.
      await ref.read(persistenceProvider).reloadForActiveAccount();

      if (mounted) context.go('/home');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      // Back button only when opened as "add server" (pushed on top of home).
      appBar: Navigator.of(context).canPop()
          ? AppBar(backgroundColor: Colors.transparent, elevation: 0, title: const Text('Add server'))
          : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 64),
                  Icon(Icons.lock_outline, size: 64, color: colorScheme.primary),
                  const SizedBox(height: 16),
                  const Text(
                    'SecureChat',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'End-to-end encrypted messaging',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 48),
                  TextFormField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      labelText: 'Server address',
                      hintText: 'https://chat.example.com',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Required';
                      final uri = Uri.tryParse(v.trim());
                      if (uri == null || uri.host.isEmpty) return 'Enter a valid address';
                      return null;
                    },
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Specify port'),
                    subtitle: const Text('Off = use 8443'),
                    value: _specifyPort,
                    onChanged: (v) => setState(() => _specifyPort = v ?? false),
                  ),
                  if (_specifyPort) ...[
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _portController,
                      decoration: const InputDecoration(
                        labelText: 'Port',
                        hintText: '8443',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.settings_ethernet),
                      ),
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      validator: (v) {
                        final p = int.tryParse((v ?? '').trim());
                        if (p == null || p < 1 || p > 65535) return 'Enter a valid port (1-65535)';
                        return null;
                      },
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                      hintText: 'satoshi',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    maxLength: 32,
                    textInputAction: TextInputAction.next,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Required';
                      if (v.trim().length < 2) return 'Minimum 2 characters';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _inviteController,
                    decoration: const InputDecoration(
                      labelText: 'Invite code',
                      hintText: 'Paste invite code here',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.vpn_key_outlined),
                      helperText: 'Required to register. Ask the server admin or an existing member.',
                    ),
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _connect(),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Invite code required';
                      return null;
                    },
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _error!,
                      style: TextStyle(color: colorScheme.error),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _loading ? null : _connect,
                    icon: _loading
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.login),
                    label: const Text('Create identity and connect'),
                  ),
                  const SizedBox(height: 64),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
