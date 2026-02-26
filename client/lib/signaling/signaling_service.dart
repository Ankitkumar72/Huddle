import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth/session_manager.dart';
import 'signaling_shield.dart';

typedef JsonMessageHandler = FutureOr<void> Function(Map<String, dynamic>);
typedef PeerHandler = FutureOr<void> Function(String peerId);
typedef ErrorHandler = FutureOr<void> Function(String error);

class SignalingService {
  final String _url;
  final String _room;
  final String _clientId;

  WebSocketChannel? _channel;

  // Callbacks for events
  JsonMessageHandler? onOffer;
  JsonMessageHandler? onAnswer;
  JsonMessageHandler? onIceCandidate;
  PeerHandler? onPeerJoined;
  PeerHandler? onPeerLeft;
  ErrorHandler? onError;

  SignalingService({
    required String url,
    required String room,
    String? clientId,
  }) : _url = url,
       _room = room,
       _clientId = clientId ?? const Uuid().v4();

  String get clientId => _clientId;

  Future<void> connect() async {
    final token = await SessionManager.getToken();
    if (token == null) {
      await _emitError('No valid session found. Please login.');
      return;
    }

    final uri = Uri.parse('$_url/?room=$_room&clientId=$_clientId&token=$token');
    debugPrint('Connecting WebSocket to ${uri.toString()}');

    try {
      _channel = WebSocketChannel.connect(uri);

      _channel!.stream.listen(
        (message) {
          unawaited(_handleIncomingMessage(message.toString()));
        },
        onDone: () {
          debugPrint('WebSocket closed');
        },
        onError: (error) {
          debugPrint('WebSocket error: $error');
          unawaited(_emitError(error.toString()));
        },
      );
    } catch (e) {
      debugPrint('Error connecting: $e');
      await _emitError(e.toString());
    }
  }

  void disconnect() {
    _channel?.sink.close();
    _channel = null;
  }

  Future<void> _handleIncomingMessage(String rawMessage) async {
    try {
      try {
        final decoded = jsonDecode(rawMessage);
        if (decoded is Map) {
          final decodedJson = decoded.map(
            (key, value) => MapEntry(key.toString(), value),
          );

          if (decodedJson['senderId'] == 'server') {
            await _handleServerEvent(decodedJson);
            return;
          }

          if (decodedJson['type'] == 'error') {
            final payload = decodedJson['payload'];
            String message = 'Unknown error';
            if (payload is Map && payload['message'] is String) {
              message = payload['message'] as String;
            }
            debugPrint('Server error: $message');

            if (payload is Map && payload['code'] == 'auth_failed') {
              await SessionManager.clearToken();
            }

            await _emitError(message);
            return;
          }
        }
      } catch (_) {
        // Not plain JSON; likely encrypted payload.
      }

      final decryptedStr = SignalingShield.decryptPayload(rawMessage);
      if (decryptedStr == null) {
        debugPrint('Failed to decrypt or parse incoming message');
        return;
      }

      final decryptedJson = jsonDecode(decryptedStr);
      if (decryptedJson is! Map) {
        debugPrint('Decrypted payload was not a JSON object');
        return;
      }

      await _handlePeerMessage(
        decryptedJson.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (e, st) {
      debugPrint('Unhandled signaling message error: $e\n$st');
      await _emitError('Signaling parse/dispatch failed');
    }
  }

  Future<void> _handleServerEvent(Map<String, dynamic> event) async {
    final type = event['type'];
    final rawPayload = event['payload'];
    if (rawPayload is! Map) {
      return;
    }

    final payload = rawPayload.map((key, value) => MapEntry(key.toString(), value));
    final peerId = payload['peerId'];
    if (peerId is! String || peerId.isEmpty) {
      return;
    }

    if (type == 'peer_joined') {
      await _callPeerHandler(onPeerJoined, peerId, 'peer_joined');
    } else if (type == 'peer_left') {
      await _callPeerHandler(onPeerLeft, peerId, 'peer_left');
    }
  }

  Future<void> _handlePeerMessage(Map<String, dynamic> message) async {
    final type = message['type'];

    if (type == 'offer') {
      await _callJsonHandler(onOffer, message, 'offer');
    } else if (type == 'answer') {
      await _callJsonHandler(onAnswer, message, 'answer');
    } else if (type == 'ice_candidate') {
      await _callJsonHandler(onIceCandidate, message, 'ice_candidate');
    } else if (type == 'peer_left') {
      final senderId = message['senderId'];
      if (senderId is String && senderId.isNotEmpty) {
        await _callPeerHandler(onPeerLeft, senderId, 'peer_left');
      }
    } else {
      debugPrint('Unknown peer message type: $type');
    }
  }

  void sendOffer(String targetId, Map<String, dynamic> sdp) {
    _sendEncryptedMessage('offer', targetId, sdp);
  }

  void sendAnswer(String targetId, Map<String, dynamic> sdp) {
    _sendEncryptedMessage('answer', targetId, sdp);
  }

  void sendIceCandidate(String targetId, Map<String, dynamic> candidate) {
    _sendEncryptedMessage('ice_candidate', targetId, candidate);
  }

  void sendPeerLeft() {
    _sendEncryptedMessage('peer_left', '*', {});
  }

  void _sendEncryptedMessage(String type, String targetId, Map<String, dynamic> payload) {
    if (_channel == null) return;

    final envelope = {
      'type': type,
      'senderId': _clientId,
      'targetId': targetId,
      'payload': payload,
    };

    final jsonStr = jsonEncode(envelope);
    final encrypted = SignalingShield.encryptPayload(jsonStr);

    if (encrypted.isEmpty) return;

    try {
      _channel!.sink.add(encrypted);
    } catch (e) {
      debugPrint('Failed to send signaling message: $e');
      unawaited(_emitError('Failed to send signaling message'));
    }
  }

  Future<void> _callJsonHandler(
    JsonMessageHandler? handler,
    Map<String, dynamic> message,
    String label,
  ) async {
    if (handler == null) return;

    try {
      await handler(message);
    } catch (e, st) {
      debugPrint('Handler error [$label]: $e\n$st');
      await _emitError('Signaling handler failed for $label');
    }
  }

  Future<void> _callPeerHandler(
    PeerHandler? handler,
    String peerId,
    String label,
  ) async {
    if (handler == null) return;

    try {
      await handler(peerId);
    } catch (e, st) {
      debugPrint('Peer handler error [$label]: $e\n$st');
      await _emitError('Signaling peer handler failed for $label');
    }
  }

  Future<void> _emitError(String error) async {
    final handler = onError;
    if (handler == null) return;

    try {
      await handler(error);
    } catch (e) {
      debugPrint('Error handler threw: $e');
    }
  }
}
