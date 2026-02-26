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

  /// Register a new passkey.
  Future<bool> register(String username, String displayName) async {
    try {
      // 1. Begin Registration (Server)
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

      // 2. Perform Passkey Registration (Client OS)
      final authenticatorResponse = await _passkeyAuthenticator.register(
        RegisterRequestType.fromJson(options),
      );

      // 3. Complete Registration (Server)
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

      return completeRes.statusCode == 200;
    } catch (e) {
      debugPrint('Passkey registration error: $e');
      return false;
    }
  }

  /// Login with an existing passkey.
  Future<bool> login(String username) async {
    try {
      // 1. Begin Login (Server)
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

      // 2. Perform Passkey Assertion (Client OS)
      final authenticatorResponse = await _passkeyAuthenticator.authenticate(
        AuthenticateRequestType.fromJson(options),
      );

      // 3. Complete Login (Server)
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

      if (completeRes.statusCode == 200) {
        final data = jsonDecode(completeRes.body) as Map<String, dynamic>;
        final token = data['token'];
        if (token is String && token.isNotEmpty) {
          await SessionManager.saveToken(token);
          return true;
        }
      }

      return false;
    } catch (e) {
      debugPrint('Passkey login error: $e');
      return false;
    }
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
}
