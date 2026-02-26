import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:jwt_decoder/jwt_decoder.dart';

class SessionManager {
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'session_jwt_token';

  /// Save token securely
  static Future<void> saveToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }

  /// Get token if valid, else null
  static Future<String?> getToken() async {
    final token = await _storage.read(key: _tokenKey);
    if (token == null) return null;

    if (JwtDecoder.isExpired(token)) {
      await clearToken();
      return null;
    }

    return token;
  }

  /// Check if user has a valid active session
  static Future<bool> hasValidSession() async {
    final token = await getToken();
    return token != null;
  }

  /// Delete the session locally
  static Future<void> clearToken() async {
    await _storage.delete(key: _tokenKey);
  }
}
