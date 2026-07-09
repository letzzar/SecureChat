import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;

  ApiException(this.statusCode, this.code, this.message);

  @override
  String toString() => 'ApiException($statusCode): [$code] $message';
}

class ApiClient {
  final String baseUrl;
  String? _jwt;

  ApiClient(this.baseUrl);

  void setJwt(String jwt) => _jwt = jwt;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_jwt != null) 'Authorization': 'Bearer $_jwt',
      };

  Future<void> checkHealth() async {
    final resp = await http
        .get(Uri.parse('$baseUrl/api/v1/health'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw ApiException(resp.statusCode, 'unreachable', 'Server health check failed');
    }
  }

  Future<String> register({
    required String userId,
    required String displayName,
    required String publicKey,
    required String signPublic,
    String inviteCode = '',
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/v1/register'),
      headers: _headers,
      body: jsonEncode({
        'user_id': userId,
        'display_name': displayName,
        'public_key': publicKey,
        'sign_public': signPublic,
        'invite_code': inviteCode,
      }),
    );
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw ApiException(resp.statusCode, body['code'] ?? 'error', body['msg'] ?? 'Unknown error');
    }
    return body['token'] as String;
  }

  Future<Map<String, dynamic>> createInvite() async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/v1/invites'),
      headers: _headers,
    );
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw ApiException(resp.statusCode, body['code'] ?? 'error', body['msg'] ?? 'Unknown error');
    }
    return body;
  }

  Future<Map<String, dynamic>> getUser(String userId) async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/v1/users/$userId'),
      headers: _headers,
    );
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw ApiException(resp.statusCode, body['code'] ?? 'error', body['msg'] ?? 'Unknown error');
    }
    return body;
  }

  Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/v1/users?q=${Uri.encodeQueryComponent(query)}'),
      headers: _headers,
    );
    if (resp.statusCode != 200) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      throw ApiException(resp.statusCode, body['code'] ?? 'error', body['msg'] ?? 'Unknown error');
    }
    final list = jsonDecode(resp.body) as List;
    return list.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> createRoom({
    required String roomId,
    required String roomName,
    required String saltHex,
    int? maxMembers,
    int? ttlHours,
  }) async {
    final body = <String, dynamic>{
      'room_id': roomId,
      'room_name': roomName,
      'salt': saltHex,
      if (maxMembers != null) 'max_members': maxMembers,
      if (ttlHours != null) 'ttl_hours': ttlHours,
    };
    final resp = await http.post(
      Uri.parse('$baseUrl/api/v1/rooms'),
      headers: _headers,
      body: jsonEncode(body),
    );
    final responseBody = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw ApiException(
        resp.statusCode,
        responseBody['code'] ?? 'error',
        responseBody['msg'] ?? 'Unknown error',
      );
    }
    return responseBody;
  }

  Future<Map<String, dynamic>> getRoom(String roomId) async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/v1/rooms/$roomId'),
      headers: _headers,
    );
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw ApiException(resp.statusCode, body['code'] ?? 'error', body['msg'] ?? 'Unknown error');
    }
    return body;
  }

  Future<Map<String, dynamic>> getFederation() async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/v1/federation'),
      headers: _headers,
    );
    if (resp.statusCode != 200) return {};
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> searchRooms(String query) async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/v1/rooms?q=${Uri.encodeQueryComponent(query)}'),
      headers: _headers,
    );
    if (resp.statusCode != 200) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      throw ApiException(resp.statusCode, body['code'] ?? 'error', body['msg'] ?? 'Unknown error');
    }
    final list = jsonDecode(resp.body) as List;
    return list.cast<Map<String, dynamic>>();
  }

  // ── Public rooms + moderation ──────────────────────────────────────────────

  Future<Map<String, dynamic>> _post(String path, [Map<String, dynamic>? body]) async {
    final resp = await http.post(
      Uri.parse('$baseUrl$path'),
      headers: _headers,
      body: body == null ? null : jsonEncode(body),
    );
    final parsed = resp.body.isEmpty ? <String, dynamic>{} : jsonDecode(resp.body);
    if (resp.statusCode != 200) {
      final m = parsed is Map<String, dynamic> ? parsed : <String, dynamic>{};
      throw ApiException(resp.statusCode, m['code'] ?? 'error', m['msg'] ?? 'Unknown error');
    }
    return parsed is Map<String, dynamic> ? parsed : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> createPublicRoom(String roomName) =>
      _post('/api/v1/rooms/public', {'room_name': roomName});

  Future<List<Map<String, dynamic>>> searchPublicRooms(String query) async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/v1/rooms/public?q=${Uri.encodeQueryComponent(query)}'),
      headers: _headers,
    );
    if (resp.statusCode != 200) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      throw ApiException(resp.statusCode, body['code'] ?? 'error', body['msg'] ?? 'Unknown error');
    }
    return (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> joinPublicRoom(String roomId) =>
      _post('/api/v1/rooms/$roomId/join');

  Future<List<Map<String, dynamic>>> roomMembers(String roomId) async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/v1/rooms/$roomId/members'),
      headers: _headers,
    );
    if (resp.statusCode != 200) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      throw ApiException(resp.statusCode, body['code'] ?? 'error', body['msg'] ?? 'Unknown error');
    }
    return (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>();
  }

  Future<void> kickMember(String roomId, String userId) =>
      _post('/api/v1/rooms/$roomId/kick', {'user_id': userId});

  Future<void> banMember(String roomId, String userId, int durationSecs) =>
      _post('/api/v1/rooms/$roomId/ban', {'user_id': userId, 'duration_secs': durationSecs});

  Future<void> unbanMember(String roomId, String userId) =>
      _post('/api/v1/rooms/$roomId/unban', {'user_id': userId});

  Future<void> setRoomAdmin(String roomId, String userId, bool grant) =>
      _post('/api/v1/rooms/$roomId/admin', {'user_id': userId, 'grant': grant});
}
