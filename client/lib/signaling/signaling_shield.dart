import 'dart:convert';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class SignalingShield {
  // A 32-character pre-shared key for encryption loaded from .env
  static String get _psk => dotenv.env['PSK'] ?? 'THIS_IS_A_DEFAULT_FALLBACK_KEY_!';
  
  static encrypt.Key get _key => encrypt.Key.fromUtf8(_psk);
  // Using AES mode CBC/PKCS7 padding by default in the encrypt package.
  static encrypt.Encrypter get _encrypter => encrypt.Encrypter(encrypt.AES(_key, mode: encrypt.AESMode.cbc));


  /// Encrypts the [payload] JSON string.
  /// Generates a random 16-byte IV per message.
  /// The returned format is `[16-byte IV][encrypted data]`, encoded in Base64.
  static String encryptPayload(String payload) {
    try {
      final iv = encrypt.IV.fromSecureRandom(16);
      final encrypted = _encrypter.encrypt(payload, iv: iv);
      
      // Combine IV (bytes) + Encrypted data (bytes)
      final combinedBytes = iv.bytes + encrypted.bytes;
      
      // Return as Base64 string
      return base64Encode(combinedBytes);
    } catch (e) {
      debugPrint('Encryption error: $e');
      // Rethrowing or handling here. Returning empty string as a safe fallback
      // so we don't accidentally send unencrypted logs.
      return '';
    }
  }

  /// Decrypts the [base64Encoded] string.
  /// Expects the format `[16-byte IV][encrypted data]`, encoded in Base64.
  /// Returns the original JSON string, or null if decryption fails.
  static String? decryptPayload(String base64Encoded) {
    try {
      final combinedBytes = base64Decode(base64Encoded);
      if (combinedBytes.length < 16) {
        debugPrint('Decryption error: Payload too small');
        return null;
      }

      // Extract IV and ciphertext
      final ivBytes = combinedBytes.sublist(0, 16);
      final cipherBytes = combinedBytes.sublist(16);

      final iv = encrypt.IV(ivBytes);
      final encrypted = encrypt.Encrypted(cipherBytes);

      // Decrypt
      final decrypted = _encrypter.decrypt(encrypted, iv: iv);
      return decrypted;
    } catch (e) {
      // Catching silent decryption failures (e.g. bad key, tampered data)
      debugPrint('Decryption error: $e');
      return null;
    }
  }
}
