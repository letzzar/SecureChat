// Noise_IK-inspired handshake for SecureChat DM sessions.
//
// Pattern (simplified, both sides know each other's static public key):
//
//   Init (A → B):
//     e_A = ephemeral X25519 keypair
//     dh1 = ECDH(e_A.priv, B.static_pub)
//     dh2 = ECDH(A.static_priv, B.static_pub)
//     session_key = BLAKE2s(dh1 ∥ dh2)
//     payload = ChaCha20-Poly1305(session_key, nonce, UTF8("noise_init") ∥ A.user_id)
//     send: { type: noise_init, e_pub: e_A.pub_hex, nonce, payload, sig }
//
//   Resp (B ← A):
//     dh1 = ECDH(B.static_priv, e_A.pub)
//     dh2 = ECDH(B.static_priv, A.static_pub)
//     session_key = BLAKE2s(dh1 ∥ dh2)
//     decrypt payload → verify "noise_init" ∥ A.user_id
//     ack_payload = ChaCha20-Poly1305(session_key, nonce2, UTF8("noise_ack"))
//     send: { type: noise_resp, nonce: nonce2, payload: ack_payload, sig }
//
// After handshake: both hold the same session_key for subsequent DM messages.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:securechat/crypto/identity.dart';
import 'package:securechat/crypto/message_crypto.dart';

const _storage = FlutterSecureStorage(
  mOptions: MacOsOptions(useDataProtectionKeyChain: false),
);
const _keyX25519Private = 'sc_x25519_private';

// In-memory session cache: peer_user_id → session_key bytes
final _sessions = <String, List<int>>{};

bool hasSession(String peerUserId) => _sessions.containsKey(peerUserId);
List<int>? getSession(String peerUserId) => _sessions[peerUserId];
void _storeSession(String peerUserId, List<int> key) => _sessions[peerUserId] = key;

/// Called by A to build the noise_init message.
/// Returns the message fields to send over WebSocket.
Future<NoiseInitData> buildNoiseInit({
  required String myUserId,
  required String peerStaticPubHex,
}) async {
  final myStaticPriv = hexToBytes(await _storage.read(key: _keyX25519Private) ?? '');
  final peerStaticPub = hexToBytes(peerStaticPubHex);

  // Generate ephemeral keypair
  final ephemeralPair = await X25519().newKeyPair();
  final ePub  = Uint8List.fromList((await ephemeralPair.extractPublicKey()).bytes);
  final ePriv = Uint8List.fromList(await ephemeralPair.extractPrivateKeyBytes());

  final dh1 = await _ecdh(ePriv, peerStaticPub);
  final dh2 = await _ecdh(myStaticPriv, peerStaticPub);
  final sessionKey = await _deriveKey(dh1, dh2);

  _storeSession(peerStaticPubHex, sessionKey);

  final plaintext = utf8.encode('noise_init') + utf8.encode(myUserId);
  final enc = await encryptMessage(plaintext, sessionKey);

  return NoiseInitData(
    ePubHex: bytesToHex(ePub),
    nonce: enc.nonce,
    payload: enc.ciphertext,
  );
}

/// Called by B upon receiving a noise_init message.
/// Derives session key, verifies the payload, returns ack fields.
Future<NoiseRespData> processNoiseInit({
  required String senderStaticPubHex, // A's static public key (from server)
  required String ePubHex,            // A's ephemeral public key
  required String nonce,
  required String payload,
}) async {
  final myStaticPriv = hexToBytes(await _storage.read(key: _keyX25519Private) ?? '');
  final senderStaticPub = hexToBytes(senderStaticPubHex);
  final ePub = hexToBytes(ePubHex);

  final dh1 = await _ecdh(myStaticPriv, ePub);
  final dh2 = await _ecdh(myStaticPriv, senderStaticPub);
  final sessionKey = await _deriveKey(dh1, dh2);

  // Decrypt and verify
  final decrypted = await decryptMessage(nonceB64: nonce, ciphertextB64: payload, key: sessionKey);
  const prefix = 'noise_init';
  final prefixBytes = utf8.encode(prefix);
  for (var i = 0; i < prefixBytes.length; i++) {
    if (decrypted[i] != prefixBytes[i]) throw StateError('Invalid noise_init payload');
  }

  _storeSession(senderStaticPubHex, sessionKey);

  final ack = await encryptMessage(utf8.encode('noise_ack'), sessionKey);
  return NoiseRespData(nonce: ack.nonce, payload: ack.ciphertext);
}

/// Called by A upon receiving noise_resp. Verifies the ACK.
Future<void> processNoiseResp({
  required String peerStaticPubHex,
  required String nonce,
  required String payload,
}) async {
  final sessionKey = _sessions[peerStaticPubHex];
  if (sessionKey == null) throw StateError('No pending noise session for $peerStaticPubHex');

  final decrypted = await decryptMessage(nonceB64: nonce, ciphertextB64: payload, key: sessionKey);
  if (utf8.decode(decrypted) != 'noise_ack') throw StateError('Invalid noise_ack');
  // Session is already stored — handshake complete.
}

// ── Internal helpers ──────────────────────────────────────────────────────────

Future<List<int>> _ecdh(List<int> privateKey, List<int> publicKey) async {
  final kp = await X25519().newKeyPairFromSeed(privateKey);
  final pub = SimplePublicKey(publicKey, type: KeyPairType.x25519);
  final shared = await X25519().sharedSecretKey(keyPair: kp, remotePublicKey: pub);
  return shared.extractBytes();
}

Future<List<int>> _deriveKey(List<int> dh1, List<int> dh2) async {
  final hash = await Blake2s(hashLengthInBytes: 32).hash(dh1 + dh2);
  return hash.bytes;
}

// ── Data classes ──────────────────────────────────────────────────────────────

class NoiseInitData {
  final String ePubHex;
  final String nonce;
  final String payload;
  const NoiseInitData({required this.ePubHex, required this.nonce, required this.payload});
}

class NoiseRespData {
  final String nonce;
  final String payload;
  const NoiseRespData({required this.nonce, required this.payload});
}
