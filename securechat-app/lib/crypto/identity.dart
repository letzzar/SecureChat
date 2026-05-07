import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'secure_kv.dart';

const _keyX25519Private = 'sc_x25519_private';
const _keyX25519Public  = 'sc_x25519_public';
const _keyEd25519Private = 'sc_ed25519_private';
const _keyEd25519Public  = 'sc_ed25519_public';
const _keyUserId      = 'sc_user_id';
const _keyDisplayName = 'sc_display_name';
const _keyServerUrl   = 'sc_server_url';
const _keyJwt         = 'sc_jwt';

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

Future<LocalIdentity?> loadIdentity() async {
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

/// Generates X25519 + Ed25519 key pairs, derives userId, saves everything, returns identity.
Future<LocalIdentity> generateAndSaveIdentity({
  required String displayName,
  required String serverUrl,
  required String jwt,
}) async {
  final x25519Pair = await X25519().newKeyPair();
  final ed25519Pair = await Ed25519().newKeyPair();

  final x25519Priv = Uint8List.fromList(await x25519Pair.extractPrivateKeyBytes());
  final x25519Pub  = Uint8List.fromList((await x25519Pair.extractPublicKey()).bytes);
  final ed25519Priv = Uint8List.fromList(await ed25519Pair.extractPrivateKeyBytes());
  final ed25519Pub  = Uint8List.fromList((await ed25519Pair.extractPublicKey()).bytes);

  final userId = await computeUserId(x25519Pub);

  await _writeAll(
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

Future<void> saveJwt(String jwt) => secureKV.write(key: _keyJwt, value: jwt);

Future<void> clearIdentity() => secureKV.deleteAll();

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

Future<void> _writeAll({
  required String userId,
  required String displayName,
  required String serverUrl,
  required String jwt,
  required Uint8List x25519Pub,
  required Uint8List x25519Priv,
  required Uint8List ed25519Pub,
  required Uint8List ed25519Priv,
}) async {
  // Sequential writes: Windows Credential Manager does not handle
  // concurrent writes reliably.
  await secureKV.write(key: _keyX25519Private, value: bytesToHex(x25519Priv));
  await secureKV.write(key: _keyX25519Public,  value: bytesToHex(x25519Pub));
  await secureKV.write(key: _keyEd25519Private, value: bytesToHex(ed25519Priv));
  await secureKV.write(key: _keyEd25519Public,  value: bytesToHex(ed25519Pub));
  await secureKV.write(key: _keyUserId,      value: userId);
  await secureKV.write(key: _keyDisplayName, value: displayName);
  await secureKV.write(key: _keyServerUrl,   value: serverUrl);
  await secureKV.write(key: _keyJwt,         value: jwt);
}
