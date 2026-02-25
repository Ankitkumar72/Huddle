import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'signaling_shield.dart';

class SignalingService {
  final String _url;
  final String _room;
  final String _clientId;
  
  WebSocketChannel? _channel;
  
  // Callbacks for events
  Function(Map<String, dynamic>)? onOffer;
  Function(Map<String, dynamic>)? onAnswer;
  Function(Map<String, dynamic>)? onIceCandidate;
  Function(String peerId)? onPeerJoined;
  Function(String peerId)? onPeerLeft;
  Function(String error)? onError;

  SignalingService({
    required String url,
    required String room,
    String? clientId,
  })  : _url = url,
        _room = room,
        _clientId = clientId ?? const Uuid().v4();

  String get clientId => _clientId;

  void connect() {
    final uri = Uri.parse('$_url/?room=$_room&clientId=$_clientId');
    debugPrint('Connecting WebSocket to ${uri.toString()}');
    
    try {
      _channel = WebSocketChannel.connect(uri);
      
      _channel!.stream.listen(
        (message) {
          _handleIncomingMessage(message.toString());
        },
        onDone: () {
          debugPrint('WebSocket closed');
        },
        onError: (error) {
          debugPrint('WebSocket error: $error');
          onError?.call(error.toString());
        },
      );
    } catch (e) {
      debugPrint('Error connecting: $e');
      onError?.call(e.toString());
    }
  }

  void disconnect() {
    _channel?.sink.close();
    _channel = null;
  }

  void _handleIncomingMessage(String rawMessage) {
    // The server routing events `peer_joined` and `peer_left`, and `error` are sent as plain JSON.
    // However, the P2P messages (offer, answer, ice_candidate) from peers are AES encrypted.
    // The server itself formats peer_joined/left. Let's try parsing as raw JSON first.
    // Server events format: {"type": "peer_joined", "senderId": "server", ...}
    // So we first attempt to decode. If it fails or it's unknown, maybe it's ciphertext.
    // Actually, based on Phase 1, the server sends unencrypted `peer_joined` and `peer_left` 
    // JSON objects. But peer messages will be fully encrypted gibberish because the server 
    // just relays what it gets. So let's handle the server messages vs peer messages.
    
    Map<String, dynamic>? decodedJson;
    try {
      decodedJson = jsonDecode(rawMessage) as Map<String, dynamic>;
      
      // If it has senderId == "server", handle it directly.
      if (decodedJson['senderId'] == 'server') {
        _handleServerEvent(decodedJson);
        return;
      } else if (decodedJson['type'] == 'error') {
        debugPrint('Server error: ${decodedJson['payload']}');
        onError?.call(decodedJson['payload']['message'] ?? 'Unknown error');
        return;
      }
    } catch (e) {
      // Not raw JSON, so it must be an encrypted peer message.
      decodedJson = null;
    }

    // Attempt decryption
    final decryptedStr = SignalingShield.decryptPayload(rawMessage);
    if (decryptedStr == null) {
      // We either failed to decrypt, or it wasn't valid. Ignore.
      debugPrint('Failed to decrypt or parsing error incoming message');
      return;
    }

    try {
      final decryptedJson = jsonDecode(decryptedStr) as Map<String, dynamic>;
      _handlePeerMessage(decryptedJson);
    } catch (e) {
      debugPrint('Decrypted string was not valid JSON: $e');
    }
  }

  void _handleServerEvent(Map<String, dynamic> event) {
    final type = event['type'];
    final payload = event['payload'] as Map<String, dynamic>;
    final peerId = payload['peerId'] as String;
    
    if (type == 'peer_joined') {
      onPeerJoined?.call(peerId);
    } else if (type == 'peer_left') {
      onPeerLeft?.call(peerId);
    }
  }

  void _handlePeerMessage(Map<String, dynamic> message) {
    final type = message['type'];
    if (type == 'offer') {
      onOffer?.call(message);
    } else if (type == 'answer') {
      onAnswer?.call(message);
    } else if (type == 'ice_candidate') {
      onIceCandidate?.call(message);
    } else if (type == 'peer_left') {
       // From Phase 4/6: local peer leaving
      onPeerLeft?.call(message['senderId']);
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
    
    if (encrypted.isNotEmpty) {
      _channel!.sink.add(encrypted);
    }
  }
}
