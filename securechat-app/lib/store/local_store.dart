// Encrypted-at-rest local store for message history and contacts.
//
// Data is serialized to JSON and encrypted with ChaCha20-Poly1305 using a
// per-device key kept in the OS secure storage (Keystore / Keychain), then
// written to the app's private support directory. Nothing readable touches
// the disk — a device backup or forensic dump cannot read the history.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:securechat/crypto/identity.dart';
import 'package:securechat/crypto/message_crypto.dart';
import 'package:securechat/crypto/secure_kv.dart';

const _deviceKeyName = 'sc_localstore_key';

Future<List<int>> _deviceKey() async {
  var hex = await secureKV.read(key: _deviceKeyName);
  if (hex == null || hex.isEmpty) {
    final rnd = Random.secure();
    final b = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      b[i] = rnd.nextInt(256);
    }
    hex = bytesToHex(b);
    await secureKV.write(key: _deviceKeyName, value: hex);
  }
  return hexToBytes(hex);
}

Future<File> _file(String name) async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}/$name');
}

/// Encrypts [data] and writes it to [name] in the app support directory.
Future<void> saveEncrypted(String name, Map<String, dynamic> data) async {
  final key = await _deviceKey();
  final enc = await encryptMessage(utf8.encode(jsonEncode(data)), key);
  final f = await _file(name);
  await f.writeAsString(jsonEncode({'n': enc.nonce, 'c': enc.ciphertext}), flush: true);
}

/// Reads and decrypts [name], or returns null if missing/unreadable.
Future<Map<String, dynamic>?> loadEncrypted(String name) async {
  try {
    final f = await _file(name);
    if (!await f.exists()) return null;
    final blob = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    final key = await _deviceKey();
    final plain = await decryptMessage(
      nonceB64: blob['n'] as String,
      ciphertextB64: blob['c'] as String,
      key: key,
    );
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// Deletes the stored blob [name] (used on logout).
Future<void> deleteEncrypted(String name) async {
  try {
    final f = await _file(name);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}
