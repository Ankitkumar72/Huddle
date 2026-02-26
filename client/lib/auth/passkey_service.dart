import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';

import 'device_fingerprint.dart';
import 'session_manager.dart';

class PasskeyService {
  final PasskeyAuthenticator _passkeyAuthenticator;

  PasskeyService() : _passkeyAuthenticator = PasskeyAuthenticator();

  String get authServerUrl =>
      dotenv.env['AUTH_SERVER_URL'] ?? 'http://127.0.0.1:8081';

  bool get _devFallbackEnabled =>
      _parseBool(dotenv.env['ENABLE_DEV_AUTH_FALLBACK'], defaultValue: true);

  /// Register a new passkey.
  Future<bool> register(String username, String displayName) async {
    try {
      return await _registerWithPasskey(username, displayName);
    } catch (e) {
      debugPrint('Passkey registration error: $e');
      if (!_devFallbackEnabled) {
        return false;
      }
      return _registerWithDevFallback(username, displayName, e.toString());
    }
  }

  /// Login with an existing passkey.
  Future<bool> login(String username) async {
    try {
      return await _loginWithPasskey(username);
    } catch (e) {
      debugPrint('Passkey login error: $e');
      if (!_devFallbackEnabled) {
        return false;
      }
      return _loginWithDevFallback(username, e.toString());
    }
  }

  Future<bool> _registerWithPasskey(String username, String displayName) async {
    final beginRes = await http.post(
      Uri.parse('$authServerUrl/register/begin'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'display_name': displayName,
      }),
    );

    if (beginRes.statusCode != 200) {
      throw Exception('Failed to begin registration: ${beginRes.body}');
    }

    final beginData = jsonDecode(beginRes.body) as Map<String, dynamic>;
    final options = _parseOptions(beginData['options']);
    final userId = beginData['user_id'];

    if (userId is! String || userId.isEmpty) {
      throw const FormatException('Missing user_id in /register/begin response');
    }

    final authenticatorResponse = await _passkeyAuthenticator.register(
      RegisterRequestType.fromJson(options),
    );

    final deviceFingerprint = await DeviceFingerprint.getFingerprint();

    final completeRes = await http.post(
      Uri.parse('$authServerUrl/register/complete'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'user_id': userId,
        'device_fingerprint': deviceFingerprint,
        'credential': authenticatorResponse.toJson(),
      }),
    );

    if (completeRes.statusCode != 200) {
      throw Exception('Failed to complete registration: ${completeRes.body}');
    }

    return true;
  }

  Future<bool> _loginWithPasskey(String username) async {
    final beginRes = await http.post(
      Uri.parse('$authServerUrl/login/begin'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username}),
    );

    if (beginRes.statusCode != 200) {
      throw Exception('Failed to begin login: ${beginRes.body}');
    }

    final beginData = jsonDecode(beginRes.body) as Map<String, dynamic>;
    final options = _parseOptions(beginData['options']);

    final authenticatorResponse = await _passkeyAuthenticator.authenticate(
      AuthenticateRequestType.fromJson(options),
    );

    final deviceFingerprint = await DeviceFingerprint.getFingerprint();

    final completeRes = await http.post(
      Uri.parse('$authServerUrl/login/complete'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'device_fingerprint': deviceFingerprint,
        'credential': authenticatorResponse.toJson(),
      }),
    );

    if (completeRes.statusCode != 200) {
      throw Exception('Failed to complete login: ${completeRes.body}');
    }

    final data = jsonDecode(completeRes.body) as Map<String, dynamic>;
    final token = data['token'];
    if (token is String && token.isNotEmpty) {
      await SessionManager.saveToken(token);
      return true;
    }

    throw const FormatException('No token in /login/complete response');
  }

  Future<bool> _registerWithDevFallback(
    String username,
    String displayName,
    String passkeyError,
  ) async {
    final deviceFingerprint = await DeviceFingerprint.getFingerprint();

    final response = await http.post(
      Uri.parse('$authServerUrl/dev/session/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'display_name': displayName,
        'device_fingerprint': deviceFingerprint,
      }),
    );

    if (response.statusCode == 200) {
      debugPrint('Using dev auth fallback for registration. Reason: $passkeyError');
      return true;
    }

    debugPrint(
      'Dev fallback registration failed: status=${response.statusCode} body=${response.body}',
    );
    return false;
  }

  Future<bool> _loginWithDevFallback(String username, String passkeyError) async {
    final deviceFingerprint = await DeviceFingerprint.getFingerprint();

    final response = await http.post(
      Uri.parse('$authServerUrl/dev/session/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'device_fingerprint': deviceFingerprint,
      }),
    );

    if (response.statusCode != 200) {
      debugPrint(
        'Dev fallback login failed: status=${response.statusCode} body=${response.body}',
      );
      return false;
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final token = data['token'];
    if (token is String && token.isNotEmpty) {
      debugPrint('Using dev auth fallback for login. Reason: $passkeyError');
      await SessionManager.saveToken(token);
      return true;
    }

    debugPrint('Dev fallback login succeeded but no token was returned.');
    return false;
  }

  Map<String, dynamic> _parseOptions(dynamic rawOptions) {
    if (rawOptions is Map<String, dynamic>) {
      return rawOptions;
    }

    if (rawOptions is Map) {
      return rawOptions.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }

    throw const FormatException('Invalid passkey options format from server');
  }

  bool _parseBool(String? raw, {required bool defaultValue}) {
    if (raw == null) {
      return defaultValue;
    }

    switch (raw.trim().toLowerCase()) {
      case '1':
      case 'true':
      case 'yes':
      case 'on':
        return true;
      case '0':
      case 'false':
      case 'no':
      case 'off':
        return false;
      default:
        return defaultValue;
    }
  }
}
