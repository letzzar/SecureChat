import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:securechat/crypto/identity.dart';
import 'package:securechat/models/message.dart';
import 'package:securechat/network/api_client.dart';
import 'package:securechat/store/local_store.dart';
import 'package:securechat/store/persistence.dart';

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

  /// Switch the active server profile. The WebSocket/API providers rebuild
  /// automatically; the local history is swapped for that account's.
  Future<void> switchServer(String userId) async {
    final id = await switchAccount(userId);
    if (id == null) return;
    state = SessionState(identity: id, isLoading: false);
    await ref.read(persistenceProvider).reloadForActiveAccount();
  }

  /// Change the server address of [userId] (same identity). If it's the active
  /// account, the WebSocket/API reconnect to the new URL automatically.
  Future<void> updateServerUrl(String userId, String newUrl) async {
    final activeChanged = await updateAccountServerUrl(userId, newUrl);
    if (activeChanged && state.identity != null) {
      final a = state.identity!;
      state = SessionState(
        identity: LocalIdentity(
          userId: a.userId,
          displayName: a.displayName,
          serverUrl: newUrl,
          jwt: a.jwt,
          x25519Public: a.x25519Public,
          ed25519Public: a.ed25519Public,
        ),
        isLoading: false,
      );
    }
    ref.invalidate(accountsProvider);
  }

  /// Remove the active account. If other servers remain, switch to one of them;
  /// otherwise return to the setup screen.
  Future<void> logout() async {
    final uid = state.identity?.userId;
    if (uid != null) await deleteEncrypted('acct_$uid.json');
    final next = uid == null ? null : await removeAccount(uid);
    state = SessionState(identity: next, isLoading: false);
    if (next != null) await ref.read(persistenceProvider).reloadForActiveAccount();
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, SessionState>(SessionNotifier.new);

// List of saved server profiles (refreshes when the active identity changes).
final accountsProvider = FutureProvider<List<AccountSummary>>((ref) {
  ref.watch(sessionProvider);
  return listAccounts();
});

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

// ── Federation ────────────────────────────────────────────────────────────────

class FederationServer {
  final String url;
  final String name;
  final int consecutiveFailures;
  final int lastSuccessMs;

  const FederationServer({
    required this.url,
    required this.name,
    this.consecutiveFailures = 0,
    this.lastSuccessMs = 0,
  });

  /// Higher score = try first. Decays with failures and time.
  double get score {
    final ageSec = (DateTime.now().millisecondsSinceEpoch - lastSuccessMs) / 1000;
    final recency = lastSuccessMs == 0 ? 0.1 : 1.0 / (1 + ageSec / 3600);
    return recency / (consecutiveFailures + 1);
  }

  FederationServer withFailure() => FederationServer(
        url: url,
        name: name,
        consecutiveFailures: consecutiveFailures + 1,
        lastSuccessMs: lastSuccessMs,
      );

  FederationServer withSuccess() => FederationServer(
        url: url,
        name: name,
        consecutiveFailures: 0,
        lastSuccessMs: DateTime.now().millisecondsSinceEpoch,
      );

  static FederationServer fromJson(Map<String, dynamic> j) => FederationServer(
        url: j['url'] as String? ?? '',
        name: j['name'] as String? ?? '',
      );
}

final federatedServersProvider =
    StateProvider<List<FederationServer>>((ref) => []);

// ── Contacts & blocking ───────────────────────────────────────────────────────

// Users whose messages go directly to the conversation (you've messaged them or accepted their request)
final acceptedContactsProvider = StateProvider<Set<String>>((ref) => {});

// Users whose messages are silently dropped
final blockedUsersProvider = StateProvider<Set<String>>((ref) => {});

// Privacy: when true, messages from people who aren't accepted contacts are
// silently dropped (strangers cannot start a conversation with you).
final blockUnknownProvider = StateProvider<bool>((ref) => false);

// ── Contact requests ──────────────────────────────────────────────────────────

class ContactRequest {
  final String fromId;
  final String displayName;
  final String pubHex;
  final List<ChatMessage> messages;

  const ContactRequest({
    required this.fromId,
    required this.displayName,
    required this.pubHex,
    required this.messages,
  });

  ContactRequest withMessage(ChatMessage msg) => ContactRequest(
        fromId: fromId,
        displayName: displayName,
        pubHex: pubHex,
        messages: [...messages, msg],
      );
}

class ContactRequestNotifier extends Notifier<List<ContactRequest>> {
  @override
  List<ContactRequest> build() => [];

  void hydrate(List<ContactRequest> requests) => state = requests;

  void addOrAppend(ContactRequest r) {
    final idx = state.indexWhere((x) => x.fromId == r.fromId);
    if (idx >= 0) {
      final updated = List<ContactRequest>.from(state);
      if (r.messages.isNotEmpty) updated[idx] = updated[idx].withMessage(r.messages.first);
      state = updated;
    } else {
      state = [...state, r];
    }
  }

  void remove(String fromId) => state = state.where((r) => r.fromId != fromId).toList();
}

final contactRequestsProvider =
    NotifierProvider<ContactRequestNotifier, List<ContactRequest>>(ContactRequestNotifier.new);
