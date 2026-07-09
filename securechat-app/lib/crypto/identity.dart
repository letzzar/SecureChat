import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'secure_kv.dart';

// ── Active slot (read by noise_handshake / signatures) ────────────────────────
const _keyX25519Private = 'sc_x25519_private';
const _keyX25519Public = 'sc_x25519_public';
const _keyEd25519Private = 'sc_ed25519_private';
const _keyEd25519Public = 'sc_ed25519_public';
const _keyUserId = 'sc_user_id';
const _keyDisplayName = 'sc_display_name';
const _keyServerUrl = 'sc_server_url';
const _keyJwt = 'sc_jwt';

// ── Accounts index (multi-server: one identity per server) ────────────────────
const _keyAccounts = 'sc_accounts'; // JSON list of AccountSummary
const _keyActive = 'sc_active'; // active userId

String _nk(String userId, String suffix) => 'acc_${userId}_$suffix';

class LocalIdentity {
  final String userId;
  final String displayName;
  final String serverUrl;
  final String jwt;
  final Uint8List x25519Public;
  final Uint8List ed25519Public;

  const LocalIdentity({
    required this.userId,
    required this.displayName,
    required this.serverUrl,
    required this.jwt,
    required this.x25519Public,
    required this.ed25519Public,
  });
}

/// A saved server profile. Each one is a full, separate identity.
class AccountSummary {
  final String userId;
  final String displayName;
  final String serverUrl;

  const AccountSummary({
    required this.userId,
    required this.displayName,
    required this.serverUrl,
  });

  Map<String, dynamic> toJson() =>
      {'userId': userId, 'displayName': displayName, 'serverUrl': serverUrl};

  static AccountSummary fromJson(Map<String, dynamic> j) => AccountSummary(
        userId: j['userId'] as String,
        displayName: j['displayName'] as String? ?? '',
        serverUrl: j['serverUrl'] as String? ?? '',
      );
}

Future<List<AccountSummary>> listAccounts() async {
  final raw = await secureKV.read(key: _keyAccounts);
  if (raw == null || raw.isEmpty) return [];
  try {
    return (jsonDecode(raw) as List)
        .map((e) => AccountSummary.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  } catch (_) {
    return [];
  }
}

Future<void> _saveAccounts(List<AccountSummary> accts) => secureKV.write(
      key: _keyAccounts,
      value: jsonEncode(accts.map((a) => a.toJson()).toList()),
    );

Future<LocalIdentity?> loadIdentity() async {
  await _migrateIfNeeded();
  final userId = await secureKV.read(key: _keyUserId);
  if (userId == null) return null;

  return LocalIdentity(
    userId: userId,
    displayName: await secureKV.read(key: _keyDisplayName) ?? '',
    serverUrl: await secureKV.read(key: _keyServerUrl) ?? '',
    jwt: await secureKV.read(key: _keyJwt) ?? '',
    x25519Public: hexToBytes(await secureKV.read(key: _keyX25519Public) ?? ''),
    ed25519Public: hexToBytes(await secureKV.read(key: _keyEd25519Public) ?? ''),
  );
}

// Existing single-identity installs have no accounts index — build one from the
// current active slot so switching/adding servers works without losing them.
Future<void> _migrateIfNeeded() async {
  final accountsRaw = await secureKV.read(key: _keyAccounts);
  if (accountsRaw != null && accountsRaw.isNotEmpty) return;
  final userId = await secureKV.read(key: _keyUserId);
  if (userId == null) return; // fresh install

  final x25519Priv = hexToBytes(await secureKV.read(key: _keyX25519Private) ?? '');
  final x25519Pub = hexToBytes(await secureKV.read(key: _keyX25519Public) ?? '');
  final ed25519Priv = hexToBytes(await secureKV.read(key: _keyEd25519Private) ?? '');
  final ed25519Pub = hexToBytes(await secureKV.read(key: _keyEd25519Public) ?? '');
  final jwt = await secureKV.read(key: _keyJwt) ?? '';
  final displayName = await secureKV.read(key: _keyDisplayName) ?? '';
  final serverUrl = await secureKV.read(key: _keyServerUrl) ?? '';

  await _writeAccountKeys(userId, x25519Pub, x25519Priv, ed25519Pub, ed25519Priv, jwt);
  await _saveAccounts([AccountSummary(userId: userId, displayName: displayName, serverUrl: serverUrl)]);
  await secureKV.write(key: _keyActive, value: userId);
}

/// Generates a fresh identity for a new server, stores it as a new account, and
/// makes it the active one. Used for both first-run and "add server".
Future<LocalIdentity> generateAndSaveIdentity({
  required String displayName,
  required String serverUrl,
  required String jwt,
}) async {
  final x25519Pair = await X25519().newKeyPair();
  final ed25519Pair = await Ed25519().newKeyPair();

  final x25519Priv = Uint8List.fromList(await x25519Pair.extractPrivateKeyBytes());
  final x25519Pub = Uint8List.fromList((await x25519Pair.extractPublicKey()).bytes);
  final ed25519Priv = Uint8List.fromList(await ed25519Pair.extractPrivateKeyBytes());
  final ed25519Pub = Uint8List.fromList((await ed25519Pair.extractPublicKey()).bytes);

  final userId = await computeUserId(x25519Pub);

  await _writeAccountKeys(userId, x25519Pub, x25519Priv, ed25519Pub, ed25519Priv, jwt);

  final accts = await listAccounts();
  if (!accts.any((a) => a.userId == userId)) {
    accts.add(AccountSummary(userId: userId, displayName: displayName, serverUrl: serverUrl));
    await _saveAccounts(accts);
  }

  await _writeActiveSlot(
    userId: userId,
    displayName: displayName,
    serverUrl: serverUrl,
    jwt: jwt,
    x25519Pub: x25519Pub,
    x25519Priv: x25519Priv,
    ed25519Pub: ed25519Pub,
    ed25519Priv: ed25519Priv,
  );

  return LocalIdentity(
    userId: userId,
    displayName: displayName,
    serverUrl: serverUrl,
    jwt: jwt,
    x25519Public: x25519Pub,
    ed25519Public: ed25519Pub,
  );
}

/// Makes [userId] the active account (rewrites the active slot). Returns the
/// identity, or null if the account is unknown.
Future<LocalIdentity?> switchAccount(String userId) async {
  final accts = await listAccounts();
  final matches = accts.where((a) => a.userId == userId).toList();
  if (matches.isEmpty) return null;
  final summary = matches.first;

  final x25519Priv = hexToBytes(await secureKV.read(key: _nk(userId, 'x25519_private')) ?? '');
  final x25519Pub = hexToBytes(await secureKV.read(key: _nk(userId, 'x25519_public')) ?? '');
  final ed25519Priv = hexToBytes(await secureKV.read(key: _nk(userId, 'ed25519_private')) ?? '');
  final ed25519Pub = hexToBytes(await secureKV.read(key: _nk(userId, 'ed25519_public')) ?? '');
  final jwt = await secureKV.read(key: _nk(userId, 'jwt')) ?? '';

  await _writeActiveSlot(
    userId: userId,
    displayName: summary.displayName,
    serverUrl: summary.serverUrl,
    jwt: jwt,
    x25519Pub: x25519Pub,
    x25519Priv: x25519Priv,
    ed25519Pub: ed25519Pub,
    ed25519Priv: ed25519Priv,
  );

  return LocalIdentity(
    userId: userId,
    displayName: summary.displayName,
    serverUrl: summary.serverUrl,
    jwt: jwt,
    x25519Public: x25519Pub,
    ed25519Public: ed25519Pub,
  );
}

/// Removes the account [userId]. Returns the next active identity, or null if no
/// accounts remain.
Future<LocalIdentity?> removeAccount(String userId) async {
  for (final s in ['x25519_private', 'x25519_public', 'ed25519_private', 'ed25519_public', 'jwt']) {
    await secureKV.delete(key: _nk(userId, s));
  }
  final remaining = (await listAccounts()).where((a) => a.userId != userId).toList();
  await _saveAccounts(remaining);

  if (remaining.isEmpty) {
    await _clearActiveSlot();
    await secureKV.delete(key: _keyActive);
    return null;
  }
  return switchAccount(remaining.first.userId);
}

Future<void> saveJwt(String jwt) async {
  await secureKV.write(key: _keyJwt, value: jwt);
  final userId = await secureKV.read(key: _keyUserId);
  if (userId != null) await secureKV.write(key: _nk(userId, 'jwt'), value: jwt);
}

/// Change the stored server URL of account [userId] (keeps the same identity
/// and JWT — e.g. switching a server from http to https). Returns true if the
/// account changed was the active one.
Future<bool> updateAccountServerUrl(String userId, String newUrl) async {
  final accts = await listAccounts();
  var found = false;
  final updated = accts.map((a) {
    if (a.userId == userId) {
      found = true;
      return AccountSummary(userId: a.userId, displayName: a.displayName, serverUrl: newUrl);
    }
    return a;
  }).toList();
  if (!found) return false;
  await _saveAccounts(updated);

  final active = await secureKV.read(key: _keyUserId);
  if (active == userId) {
    await secureKV.write(key: _keyServerUrl, value: newUrl);
    return true;
  }
  return false;
}

/// Full wipe of ALL accounts and keys (hard reset).
Future<void> clearIdentity() => secureKV.deleteAll();

Future<void> _writeAccountKeys(
  String userId,
  Uint8List x25519Pub,
  Uint8List x25519Priv,
  Uint8List ed25519Pub,
  Uint8List ed25519Priv,
  String jwt,
) async {
  await secureKV.write(key: _nk(userId, 'x25519_private'), value: bytesToHex(x25519Priv));
  await secureKV.write(key: _nk(userId, 'x25519_public'), value: bytesToHex(x25519Pub));
  await secureKV.write(key: _nk(userId, 'ed25519_private'), value: bytesToHex(ed25519Priv));
  await secureKV.write(key: _nk(userId, 'ed25519_public'), value: bytesToHex(ed25519Pub));
  await secureKV.write(key: _nk(userId, 'jwt'), value: jwt);
}

Future<void> _writeActiveSlot({
  required String userId,
  required String displayName,
  required String serverUrl,
  required String jwt,
  required Uint8List x25519Pub,
  required Uint8List x25519Priv,
  required Uint8List ed25519Pub,
  required Uint8List ed25519Priv,
}) async {
  // Sequential writes: Windows Credential Manager does not handle concurrent
  // writes reliably.
  await secureKV.write(key: _keyX25519Private, value: bytesToHex(x25519Priv));
  await secureKV.write(key: _keyX25519Public, value: bytesToHex(x25519Pub));
  await secureKV.write(key: _keyEd25519Private, value: bytesToHex(ed25519Priv));
  await secureKV.write(key: _keyEd25519Public, value: bytesToHex(ed25519Pub));
  await secureKV.write(key: _keyUserId, value: userId);
  await secureKV.write(key: _keyDisplayName, value: displayName);
  await secureKV.write(key: _keyServerUrl, value: serverUrl);
  await secureKV.write(key: _keyJwt, value: jwt);
  await secureKV.write(key: _keyActive, value: userId);
}

Future<void> _clearActiveSlot() async {
  for (final k in [
    _keyX25519Private,
    _keyX25519Public,
    _keyEd25519Private,
    _keyEd25519Public,
    _keyUserId,
    _keyDisplayName,
    _keyServerUrl,
    _keyJwt,
  ]) {
    await secureKV.delete(key: k);
  }
}

/// user_id = BLAKE2s-256(x25519_public_key), hex-encoded
Future<String> computeUserId(List<int> x25519PublicKey) async {
  final hash = await Blake2s(hashLengthInBytes: 32).hash(x25519PublicKey);
  return bytesToHex(Uint8List.fromList(hash.bytes));
}

String bytesToHex(Uint8List bytes) {
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

Uint8List hexToBytes(String hex) {
  if (hex.isEmpty) return Uint8List(0);
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}
