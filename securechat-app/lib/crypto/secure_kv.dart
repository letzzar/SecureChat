import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

// Single shared instance used by all crypto modules.
final secureKV = _SecureKV();

class _SecureKV {
  static const _fss = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  bool get _mac => !kIsWeb && Platform.isMacOS;

  Future<String?> read({required String key}) =>
      _mac ? _MacFile.instance.read(key) : _fss.read(key: key);

  Future<void> write({required String key, required String value}) =>
      _mac ? _MacFile.instance.write(key, value) : _fss.write(key: key, value: value);

  Future<void> delete({required String key}) =>
      _mac ? _MacFile.instance.delete(key) : _fss.delete(key: key);

  Future<void> deleteAll() =>
      _mac ? _MacFile.instance.deleteAll() : _fss.deleteAll();
}

// macOS backend: JSON file in Application Support, no Keychain, no prompts.
class _MacFile {
  _MacFile._();
  static final instance = _MacFile._();

  Map<String, String>? _cache;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/sc_keys.json');
  }

  Future<Map<String, String>> _load() async {
    if (_cache != null) return _cache!;
    try {
      final f = await _file();
      if (await f.exists()) {
        _cache = Map<String, String>.from(jsonDecode(await f.readAsString()) as Map);
      } else {
        _cache = {};
      }
    } catch (_) {
      _cache = {};
    }
    return _cache!;
  }

  Future<void> _flush() async {
    final f = await _file();
    await f.writeAsString(jsonEncode(_cache ?? {}));
  }

  Future<String?> read(String key) async => (await _load())[key];

  Future<void> write(String key, String value) async {
    (await _load())[key] = value;
    await _flush();
  }

  Future<void> delete(String key) async {
    (await _load()).remove(key);
    await _flush();
  }

  Future<void> deleteAll() async {
    _cache = {};
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}
