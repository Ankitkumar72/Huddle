import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class DeviceFingerprint {
  static const _storage = FlutterSecureStorage();
  static const _uuidKey = 'device_install_uuid';

  static Future<String> getFingerprint() async {
    final Map<String, String> components = {};

    // 1. Get or generate install UUID
    String? installUuid = await _storage.read(key: _uuidKey);
    if (installUuid == null) {
      installUuid = const Uuid().v4();
      await _storage.write(key: _uuidKey, value: installUuid);
    }
    components['installUuid'] = installUuid;

    // 2. Add Hardware Info
    final deviceInfo = DeviceInfoPlugin();
    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        components['model'] = androidInfo.model;
        components['manufacturer'] = androidInfo.manufacturer;
        components['osVersion'] = androidInfo.version.release;
        components['hardware'] = androidInfo.hardware;
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        components['model'] = iosInfo.model;
        components['name'] = iosInfo.name;
        components['systemName'] = iosInfo.systemName;
        components['systemVersion'] = iosInfo.systemVersion;
        components['identifierForVendor'] = iosInfo.identifierForVendor ?? '';
      } else if (Platform.isWindows) {
        final windowsInfo = await deviceInfo.windowsInfo;
        components['computerName'] = windowsInfo.computerName;
        components['numberOfCores'] = windowsInfo.numberOfCores.toString();
      } else if (Platform.isMacOS) {
        final macInfo = await deviceInfo.macOsInfo;
        components['model'] = macInfo.model;
        components['osRelease'] = macInfo.osRelease;
      } else {
        components['platform'] = Platform.operatingSystem;
      }
    } catch (e) {
      // Fallback
      components['platform'] = Platform.operatingSystem;
    }

    // 3. Hash to finalize
    final sortedKeys = components.keys.toList()..sort();
    final buffer = StringBuffer();
    for (var key in sortedKeys) {
      buffer.write('$key:${components[key]}|');
    }

    final bytes = utf8.encode(buffer.toString());
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
}
