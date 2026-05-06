import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:securechat/screens/home/home_screen.dart';
import 'package:securechat/screens/setup/server_setup_screen.dart';
import 'package:securechat/store/app_state.dart';
import 'package:securechat/store/messages_store.dart';

final _router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, __) => const _SplashRedirect()),
    GoRoute(path: '/setup', builder: (_, __) => const ServerSetupScreen()),
    GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
  ],
);

class SecureChatApp extends ConsumerWidget {
  const SecureChatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'SecureChat',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1976D2)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1976D2),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      routerConfig: _router,
    );
  }
}

/// Redirect based on session state + wire WS listener
class _SplashRedirect extends ConsumerStatefulWidget {
  const _SplashRedirect();

  @override
  ConsumerState<_SplashRedirect> createState() => _SplashRedirectState();
}

class _SplashRedirectState extends ConsumerState<_SplashRedirect> {
  StreamSubscription<Map<String, dynamic>>? _wsSub;

  @override
  void dispose() {
    _wsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);

    if (session.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (session.isAuthenticated) {
      ref.listen(wsClientProvider, (prev, ws) {
        _wsSub?.cancel();
        _wsSub = ws?.messages.listen((msg) => dispatchIncoming(msg, ref));
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (session.isAuthenticated) {
        context.go('/home');
      } else {
        context.go('/setup');
      }
    });

    return const Scaffold(body: SizedBox());
  }
}
