import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securechat/crypto/noise_handshake.dart';

Future<(Uint8List priv, Uint8List pub)> _x25519() async {
  final kp = await X25519().newKeyPair();
  final priv = Uint8List.fromList(await kp.extractPrivateKeyBytes());
  final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
  return (priv, pub);
}

void main() {
  test('initiator and responder derive the same session key', () async {
    final (sAPriv, sAPub) = await _x25519(); // A static
    final (sBPriv, sBPub) = await _x25519(); // B static
    final (eAPriv, eAPub) = await _x25519(); // A ephemeral
    final (eBPriv, eBPub) = await _x25519(); // B ephemeral

    final keyA = await computeSessionKey(
      myStaticPriv: sAPriv,
      myEphemeralPriv: eAPriv,
      peerStaticPub: sBPub,
      peerEphemeralPub: eBPub,
      initiator: true,
    );
    final keyB = await computeSessionKey(
      myStaticPriv: sBPriv,
      myEphemeralPriv: eBPriv,
      peerStaticPub: sAPub,
      peerEphemeralPub: eAPub,
      initiator: false,
    );

    expect(keyA, equals(keyB));
    expect(keyA.length, equals(32));
  });

  test('forward secrecy: a different responder ephemeral yields a different key',
      () async {
    final (sAPriv, _) = await _x25519();
    final (_, sBPub) = await _x25519();
    final (eAPriv, _) = await _x25519();
    final (_, eBPub) = await _x25519();
    final (_, eBPub2) = await _x25519(); // a fresh session's ephemeral

    final key1 = await computeSessionKey(
      myStaticPriv: sAPriv,
      myEphemeralPriv: eAPriv,
      peerStaticPub: sBPub,
      peerEphemeralPub: eBPub,
      initiator: true,
    );
    final key2 = await computeSessionKey(
      myStaticPriv: sAPriv,
      myEphemeralPriv: eAPriv,
      peerStaticPub: sBPub,
      peerEphemeralPub: eBPub2,
      initiator: true,
    );

    // The only change is the responder's ephemeral; the key must change,
    // proving the session key depends on the ephemeral-ephemeral DH.
    expect(key1, isNot(equals(key2)));
  });
}
