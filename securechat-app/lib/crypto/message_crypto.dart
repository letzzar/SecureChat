import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final _chacha = Chacha20.poly1305Aead();
final _random = Random.secure();

/// Encrypts [plaintext] with [key] (32 bytes).
/// Returns a base64-encoded string of nonce(12) || ciphertext+tag.
Future<({String nonce, String ciphertext})> encryptMessage(
  List<int> plaintext,
  List<int> key,
) async {
  final nonce = _randomBytes(12);
  final secretKey = SecretKey(key);

  final box = await _chacha.encrypt(
    plaintext,
    secretKey: secretKey,
    nonce: nonce,
  );

  return (
    nonce: base64Encode(nonce),
    ciphertext: base64Encode(box.cipherText + box.mac.bytes),
  );
}

/// Decrypts a message previously encrypted with [encryptMessage].
Future<Uint8List> decryptMessage({
  required String nonceB64,
  required String ciphertextB64,
  required List<int> key,
}) async {
  final nonce = base64Decode(nonceB64);
  final raw = base64Decode(ciphertextB64);

  // raw = ciphertext(N) + mac(16)
  if (raw.length < 16) throw const FormatException('Ciphertext too short');
  final cipherText = raw.sublist(0, raw.length - 16);
  final mac = Mac(raw.sublist(raw.length - 16));

  final secretKey = SecretKey(key);
  final box = SecretBox(cipherText, nonce: nonce, mac: mac);

  final plaintext = await _chacha.decrypt(box, secretKey: secretKey);
  return Uint8List.fromList(plaintext);
}

List<int> _randomBytes(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = _random.nextInt(256);
  }
  return bytes;
}
