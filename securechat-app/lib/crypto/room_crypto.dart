import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Derives the 32-byte room key and the room_id (hex) from password + salt.
/// salt must be 16 raw bytes.
Future<({Uint8List roomKey, String roomId})> deriveRoomKey(
  String password,
  Uint8List salt,
) async {
  final argon2 = Argon2id(
    memory: 65536,
    parallelism: 4,
    iterations: 3,
    hashLength: 32,
  );
  final secretKey = await argon2.deriveKey(
    secretKey: SecretKey(utf8.encode(password)),
    nonce: salt,
  );
  final roomKey = Uint8List.fromList(await secretKey.extractBytes());

  // room_id = BLAKE2s(room_key) hex
  final blake2s = Blake2s();
  final hash = await blake2s.hash(roomKey);
  final roomId = _bytesToHex(hash.bytes);

  return (roomKey: roomKey, roomId: roomId);
}

/// Encrypts plaintext for a room.
/// Returns base64(12-byte nonce || ciphertext || 16-byte mac).
Future<String> encryptRoomMessage(String plaintext, Uint8List roomKey) async {
  final nonce = Uint8List(12);
  final rng = Random.secure();
  for (var i = 0; i < 12; i++) {
    nonce[i] = rng.nextInt(256);
  }

  final aead = Chacha20.poly1305Aead();
  final sk = SecretKey(roomKey);

  final box = await aead.encrypt(
    utf8.encode(plaintext),
    secretKey: sk,
    nonce: nonce,
  );

  final combined = Uint8List(12 + box.cipherText.length + box.mac.bytes.length)
    ..setAll(0, nonce)
    ..setAll(12, box.cipherText)
    ..setAll(12 + box.cipherText.length, box.mac.bytes);

  return base64.encode(combined);
}

/// Decrypts a base64-encoded room message blob.
Future<String> decryptRoomMessage(String blob, Uint8List roomKey) async {
  final combined = base64.decode(blob);
  const nonceLen = 12;
  const macLen = 16;
  if (combined.length < nonceLen + macLen) {
    throw Exception('Room message too short');
  }

  final nonceBytes = combined.sublist(0, nonceLen);
  final cipherText = combined.sublist(nonceLen, combined.length - macLen);
  final macBytes = combined.sublist(combined.length - macLen);

  final aead = Chacha20.poly1305Aead();
  final sk = SecretKey(roomKey);

  final plainBytes = await aead.decrypt(
    SecretBox(cipherText, nonce: nonceBytes, mac: Mac(macBytes)),
    secretKey: sk,
  );
  return utf8.decode(plainBytes);
}

String _bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
