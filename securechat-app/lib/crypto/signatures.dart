import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:securechat/crypto/identity.dart';

const _storage = FlutterSecureStorage();
const _keyEd25519Private = 'sc_ed25519_private';
const _keyEd25519Public  = 'sc_ed25519_public';

/// Signs [data] with the local Ed25519 private key.
/// Returns the 64-byte signature as hex.
Future<String> signData(List<int> data) async {
  final privHex = await _storage.read(key: _keyEd25519Private) ?? '';
  final pubHex  = await _storage.read(key: _keyEd25519Public)  ?? '';

  final privBytes = hexToBytes(privHex);
  final kp = await Ed25519().newKeyPairFromSeed(privBytes);

  final derivedPub = await kp.extractPublicKey();
  if (bytesToHex(Uint8List.fromList(derivedPub.bytes)) != pubHex) {
    throw StateError('Ed25519 key mismatch in secure storage');
  }

  final sig = await Ed25519().sign(data, keyPair: kp);
  return bytesToHex(Uint8List.fromList(sig.bytes));
}

/// Verifies an Ed25519 [sigHex] (hex 64 bytes) against [pubKeyHex] (hex 32 bytes).
Future<bool> verifySignature({
  required List<int> data,
  required String sigHex,
  required String pubKeyHex,
}) async {
  final sigBytes = hexToBytes(sigHex);
  final pubBytes = hexToBytes(pubKeyHex);

  final pubKey = SimplePublicKey(pubBytes, type: KeyPairType.ed25519);
  final sig = Signature(sigBytes, publicKey: pubKey);
  return Ed25519().verify(data, signature: sig);
}
