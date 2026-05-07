import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:securechat/crypto/identity.dart';
import 'package:securechat/network/api_client.dart';

// ── Session state ─────────────────────────────────────────────────────────────

class SessionState {
  final LocalIdentity? identity;
  final bool isLoading;

  const SessionState({this.identity, this.isLoading = false});

  bool get isAuthenticated => identity != null;

  SessionState copyWith({LocalIdentity? identity, bool? isLoading}) => SessionState(
        identity: identity ?? this.identity,
        isLoading: isLoading ?? this.isLoading,
      );
}

class SessionNotifier extends Notifier<SessionState> {
  @override
  SessionState build() => const SessionState(isLoading: true);

  Future<void> load() async {
    state = state.copyWith(isLoading: true);
    try {
      final identity = await loadIdentity();
      state = SessionState(identity: identity, isLoading: false);
    } catch (_) {
      // Keychain/storage error (e.g. iOS PlatformException after crash).
      // Clear any corrupt state and treat as fresh install.
      try { await clearIdentity(); } catch (_) {}
      state = const SessionState(isLoading: false);
    }
  }

  Future<void> setIdentity(LocalIdentity identity) async {
    state = SessionState(identity: identity, isLoading: false);
  }

  Future<void> logout() async {
    await clearIdentity();
    state = const SessionState(isLoading: false);
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, SessionState>(SessionNotifier.new);

// ── Known peers (userId → server user JSON) ───────────────────────────────────

final knownPeersProvider = StateProvider<Map<String, Map<String, dynamic>>>((ref) => {});

// ── ApiClient provider ────────────────────────────────────────────────────────

final apiClientProvider = Provider<ApiClient?>((ref) {
  final session = ref.watch(sessionProvider);
  final identity = session.identity;
  if (identity == null) return null;
  final client = ApiClient(identity.serverUrl);
  client.setJwt(identity.jwt);
  return client;
});
