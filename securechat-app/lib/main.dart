import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:securechat/app.dart';
import 'package:securechat/store/app_state.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final container = ProviderContainer();
  await container.read(sessionProvider.notifier).load();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const SecureChatApp(),
    ),
  );
}
