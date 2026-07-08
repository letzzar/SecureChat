import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:securechat/app.dart';
import 'package:securechat/store/app_state.dart';
import 'package:securechat/store/persistence.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final container = ProviderContainer();
  await container.read(sessionProvider.notifier).load();
  // Restore encrypted message/room history before the UI reads any state.
  if (container.read(sessionProvider).isAuthenticated) {
    await container.read(persistenceProvider).hydrate();
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const SecureChatApp(),
    ),
  );
}
