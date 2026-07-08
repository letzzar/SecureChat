// Noise_IK-inspired handshake for SecureChat DM sessions, now with forward
// secrecy: the responder contributes an ephemeral key so the session key mixes
// an ephemeral-ephemeral DH (ee). Once both ephemerals are discarded, a later
// compromise of either party's static key does not reveal past session keys.
//
//   Message 1 (A -> B):  e_A   (payload encrypted with BLAKE2s(es || ss))
//   Message 2 (B -> A):  e_B   (ack encrypted with the final session key)
//
//   Final session key (both sides): BLAKE2s(es || ss || ee || se)
//     es = DH(e_A, s_B)   ss = DH(s_A, s_B)
//     ee = DH(e_A, e_B)   se = DH(s_A, e_B)
//
// Trade-off: because the key needs e_B, A cannot derive it alone, so the first
// DM is sent only after the handshake round-trips (see messages_store.dart). A
// message to a peer who is offline at send time waits locally until the
// handshake completes. Async delivery to long-offline peers would need
// published prekeys (X3DH) — a future iteration.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:securechat/crypto/identity.dart';
import 'package:securechat/crypto/message_crypto.dart';
import 'package:securechat/crypto/secure_kv.dart';

const _keyX25519Private = 'sc_x25519_private';

// Completed sessions: peer_static_pub_hex → session_key bytes
final _sessions = <String, List<int>>{};

// In-flight initiator handshakes: peer_static_pub_hex → state needed to finish
// key derivation when the noise_resp (carrying e_B) arrives.
final _pending = <String, _PendingInit>{};

class _PendingInit {
  final List<int> ephemeralPriv; // e_A private
  final List<int> staticPriv;    // s_A private
  final List<int> peerStaticPub; // s_B public
  const _PendingInit(this.ephemeralPriv, this.staticPriv, this.peerStaticPub);
}

bool hasSession(String peerUserId) => _sessions.containsKey(peerUserId);
List<int>? getSession(String peerUserId) => _sessions[peerUserId];
void _storeSession(String peerUserId, List<int> key) => _sessions[peerUserId] = key;

/// Drop all in-memory sessions and pending handshakes (on account switch).
void clearNoiseSessions() {
  _sessions.clear();
  _pending.clear();
}

/// Called by A to build the noise_init message.
Future<NoiseInitData> buildNoiseInit({
  required String myUserId,
  required String peerStaticPubHex,
}) async {
  final myStaticPriv = hexToBytes(await secureKV.read(key: _keyX25519Private) ?? '');
  final peerStaticPub = hexToBytes(peerStaticPubHex);

  // Fresh ephemeral for this handshake.
  final ephemeralPair = await X25519().newKeyPair();
  final ePub  = Uint8List.fromList((await ephemeralPair.extractPublicKey()).bytes);
  final ePriv = Uint8List.fromList(await ephemeralPair.extractPrivateKeyBytes());

  // Message-1 key uses only es and ss (B's ephemeral is not known yet).
  final es = await _ecdh(ePriv, peerStaticPub);
  final ss = await _ecdh(myStaticPriv, peerStaticPub);
  final k1 = await _blake2s(es + ss);

  // Retain what we need to finish the key once B's ephemeral arrives.
  _pending[peerStaticPubHex] = _PendingInit(ePriv, myStaticPriv, peerStaticPub);

  final plaintext = utf8.encode('noise_init') + utf8.encode(myUserId);
  final enc = await encryptMessage(plaintext, k1);

  return NoiseInitData(
    ePubHex: bytesToHex(ePub),
    nonce: enc.nonce,
    payload: enc.ciphertext,
  );
}

/// Called by B upon receiving a noise_init. Verifies it, contributes an
/// ephemeral, derives the forward-secret session key, and returns the ack.
Future<NoiseRespData> processNoiseInit({
  required String senderStaticPubHex, // A's static public key (from server)
  required String ePubHex,            // A's ephemeral public key
  required String nonce,
  required String payload,
}) async {
  final myStaticPriv = hexToBytes(await secureKV.read(key: _keyX25519Private) ?? '');
  final senderStaticPub = hexToBytes(senderStaticPubHex);
  final eaPub = hexToBytes(ePubHex);

  // Recover the message-1 key and verify the payload.
  final es = await _ecdh(myStaticPriv, eaPub);
  final ss = await _ecdh(myStaticPriv, senderStaticPub);
  final k1 = await _blake2s(es + ss);

  final decrypted = await decryptMessage(nonceB64: nonce, ciphertextB64: payload, key: k1);
  const prefix = 'noise_init';
  final prefixBytes = utf8.encode(prefix);
  for (var i = 0; i < prefixBytes.length; i++) {
    if (decrypted[i] != prefixBytes[i]) throw StateError('Invalid noise_init payload');
  }

  // Contribute our ephemeral and derive the final key.
  final ebPair = await X25519().newKeyPair();
  final ebPub  = Uint8List.fromList((await ebPair.extractPublicKey()).bytes);
  final ebPriv = Uint8List.fromList(await ebPair.extractPrivateKeyBytes());

  final sessionKey = await computeSessionKey(
    myStaticPriv: myStaticPriv,
    myEphemeralPriv: ebPriv,
    peerStaticPub: senderStaticPub,
    peerEphemeralPub: eaPub,
    initiator: false,
  );
  _storeSession(senderStaticPubHex, sessionKey);

  final ack = await encryptMessage(utf8.encode('noise_ack'), sessionKey);
  return NoiseRespData(ePubHex: bytesToHex(ebPub), nonce: ack.nonce, payload: ack.ciphertext);
}

/// Called by A upon receiving noise_resp. Completes the key with B's ephemeral
/// and verifies the ACK.
Future<void> processNoiseResp({
  required String peerStaticPubHex,
  required String ePubHex, // B's ephemeral public key
  required String nonce,
  required String payload,
}) async {
  final pending = _pending[peerStaticPubHex];
  if (pending == null) throw StateError('No pending noise session for $peerStaticPubHex');

  final sessionKey = await computeSessionKey(
    myStaticPriv: pending.staticPriv,
    myEphemeralPriv: pending.ephemeralPriv,
    peerStaticPub: pending.peerStaticPub,
    peerEphemeralPub: hexToBytes(ePubHex),
    initiator: true,
  );

  final decrypted = await decryptMessage(nonceB64: nonce, ciphertextB64: payload, key: sessionKey);
  if (utf8.decode(decrypted) != 'noise_ack') throw StateError('Invalid noise_ack');

  _storeSession(peerStaticPubHex, sessionKey);
  _pending.remove(peerStaticPubHex);
}

/// Derives the forward-secret session key from the four Noise DH operations.
/// Pure and deterministic — exercised directly by the unit test.
Future<List<int>> computeSessionKey({
  required List<int> myStaticPriv,
  required List<int> myEphemeralPriv,
  required List<int> peerStaticPub,
  required List<int> peerEphemeralPub,
  required bool initiator,
}) async {
  final List<int> es, ss, ee, se;
  if (initiator) {
    es = await _ecdh(myEphemeralPriv, peerStaticPub);
    ss = await _ecdh(myStaticPriv, peerStaticPub);
    ee = await _ecdh(myEphemeralPriv, peerEphemeralPub);
    se = await _ecdh(myStaticPriv, peerEphemeralPub);
  } else {
    es = await _ecdh(myStaticPriv, peerEphemeralPub);
    ss = await _ecdh(myStaticPriv, peerStaticPub);
    ee = await _ecdh(myEphemeralPriv, peerEphemeralPub);
    se = await _ecdh(myEphemeralPriv, peerStaticPub);
  }
  return _blake2s(es + ss + ee + se);
}

// ── Internal helpers ──────────────────────────────────────────────────────────

Future<List<int>> _ecdh(List<int> privateKey, List<int> publicKey) async {
  final kp = await X25519().newKeyPairFromSeed(privateKey);
  final pub = SimplePublicKey(publicKey, type: KeyPairType.x25519);
  final shared = await X25519().sharedSecretKey(keyPair: kp, remotePublicKey: pub);
  return shared.extractBytes();
}

Future<List<int>> _blake2s(List<int> data) async {
  final hash = await Blake2s(hashLengthInBytes: 32).hash(data);
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
  final String ePubHex;
  final String nonce;
  final String payload;
  const NoiseRespData({required this.ePubHex, required this.nonce, required this.payload});
}
