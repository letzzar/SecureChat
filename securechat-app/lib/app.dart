import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:securechat/network/ws_client.dart';
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

// Root widget — lives for the entire app lifetime.
// Wires the WS message listener here so it survives all navigation.
class SecureChatApp extends ConsumerStatefulWidget {
  const SecureChatApp({super.key});

  @override
  ConsumerState<SecureChatApp> createState() => _SecureChatAppState();
}

class _SecureChatAppState extends ConsumerState<SecureChatApp> {
  StreamSubscription<Map<String, dynamic>>? _wsSub;
  // Serial queue: each message waits for the previous handler to complete
  // before starting. Prevents noise_init / dm race on first contact.
  Future<void> _msgQueue = Future.value();

  @override
  void initState() {
    super.initState();
    // fireImmediately wires the listener right away if a WsClient already exists.
    ref.listenManual(wsClientProvider, (_, ws) => _rewire(ws),
        fireImmediately: true);
  }

  void _rewire(WsClient? ws) {
    _wsSub?.cancel();
    _msgQueue = Future.value();
    if (ws == null) return;

    // Fetch federation peer list so the UI can show backup servers.
    ref.read(apiClientProvider)?.getFederation().then((info) {
      final peers = (info['peers'] as List? ?? []).cast<Map<String, dynamic>>();
      final servers = peers
          .map((p) => FederationServer.fromJson(p))
          .where((s) => s.url.isNotEmpty)
          .toList();
      ref.read(federatedServersProvider.notifier).state = servers;
    }).catchError((_) {});

    _wsSub = ws.messages.listen((msg) {
      _msgQueue = _msgQueue
          .then((_) => dispatchIncoming(msg, ref))
          .catchError((_) {}); // Prevent one bad message from stalling the queue
    });
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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

// Redirect splash — now stateless, no longer owns the WS subscription.
class _SplashRedirect extends ConsumerWidget {
  const _SplashRedirect();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);

    if (session.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
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
