import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../signaling/signaling_service.dart';

class WebRtcEngine {
  final SignalingService _signaling;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  RTCVideoRenderer? localRenderer;
  RTCVideoRenderer? remoteRenderer;

  bool _isDisposed = false;

  // UI callbacks
  Function()? onLocalStreamReady;
  Function()? onRemoteStreamReady;
  Function(String)? onError;

  WebRtcEngine({required SignalingService signaling}) : _signaling = signaling;

  Future<void> initialize(RTCVideoRenderer local, RTCVideoRenderer remote) async {
    localRenderer = local;
    remoteRenderer = remote;

    // 1. Hook up signaling events
    _signaling.onPeerJoined = _handlePeerJoined;
    _signaling.onPeerLeft = _handlePeerLeft;
    _signaling.onOffer = _handleReceiveOffer;
    _signaling.onAnswer = _handleReceiveAnswer;
    _signaling.onIceCandidate = _handleReceiveIceCandidate;
    _signaling.onError = (err) {
      if (!_isDisposed) onError?.call('Signaling Error: $err');
    };

    // 2. Open Camera/Mic
    await _openUserMedia();

    // 3. Connect to signaling server
    await _signaling.connect();
  }

  Future<void> _openUserMedia() async {
    try {
      final mediaConstraints = <String, dynamic>{
        'audio': true,
        'video': {
          'facingMode': 'user',
        }
      };

      _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      localRenderer?.srcObject = _localStream;
      onLocalStreamReady?.call();
    } catch (e) {
      debugPrint('Error accessing local media: $e');
      onError?.call('Could not access camera/microphone');
    }
  }

  Future<void> _createPeerConnection() async {
    if (_peerConnection != null || _isDisposed) return;

    try {
      final config = {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          // Note: Add TURN server here if strict NAT traversal is required.
        ],
        'sdpSemantics': 'unified-plan',
      };

      _peerConnection = await createPeerConnection(config);

      // Add local tracks to peer connection
      final stream = _localStream;
      if (stream != null) {
        for (final track in stream.getTracks()) {
          await _peerConnection!.addTrack(track, stream);
        }
      }

      // Handle remote stream
      _peerConnection!.onTrack = (event) {
        if (_isDisposed) return;
        if (event.track.kind != 'video') return;

        if (event.streams.isEmpty) {
          debugPrint('Received video track without streams; ignoring event.');
          return;
        }

        remoteRenderer?.srcObject = event.streams.first;
        onRemoteStreamReady?.call();
      };

      // Handle outgoing ICE candidates
      _peerConnection!.onIceCandidate = (candidate) {
        if (_isDisposed) return;

        final value = candidate.candidate;
        if (value == null || value.isEmpty) return;

        _signaling.sendIceCandidate('*', {
          'candidate': value,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      };

      _peerConnection!.onConnectionState = (state) {
        debugPrint('Connection state changed: $state');
      };
    } catch (e) {
      debugPrint('Failed to create peer connection: $e');
      onError?.call('Failed to initialize call connection');
      rethrow;
    }
  }

  // ---- Signaling Handshake Logic ----

  Future<void> _handlePeerJoined(String peerId) async {
    if (_isDisposed) return;

    try {
      debugPrint('Peer joined: $peerId. Initiating handshake...');
      await _createPeerConnection();

      final pc = _peerConnection;
      if (pc == null) {
        onError?.call('Call connection is not ready');
        return;
      }

      // Existing user creates the offer.
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      _signaling.sendOffer(peerId, {
        'sdp': offer.sdp,
        'type': offer.type,
      });
    } catch (e) {
      debugPrint('Failed during peer-joined offer flow: $e');
      onError?.call('Failed to start call handshake');
    }
  }

  Future<void> _handleReceiveOffer(Map<String, dynamic> message) async {
    if (_isDisposed) return;

    try {
      final senderId = message['senderId'];
      final payload = message['payload'];

      if (senderId is! String || senderId.isEmpty || payload is! Map) {
        debugPrint('Malformed offer message: $message');
        return;
      }

      final sdp = payload['sdp'];
      final type = payload['type'];
      if (sdp is! String || type is! String) {
        debugPrint('Malformed offer payload: $payload');
        return;
      }

      debugPrint('Received Offer from: $senderId');
      await _createPeerConnection();

      final pc = _peerConnection;
      if (pc == null) return;

      final offerSession = RTCSessionDescription(sdp, type);
      await pc.setRemoteDescription(offerSession);

      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);

      _signaling.sendAnswer(senderId, {
        'sdp': answer.sdp,
        'type': answer.type,
      });
    } catch (e) {
      debugPrint('Failed handling remote offer: $e');
      onError?.call('Failed to handle incoming offer');
    }
  }

  Future<void> _handleReceiveAnswer(Map<String, dynamic> message) async {
    if (_isDisposed) return;

    try {
      final payload = message['payload'];
      if (_peerConnection == null || payload is! Map) return;

      final sdp = payload['sdp'];
      final type = payload['type'];
      if (sdp is! String || type is! String) {
        debugPrint('Malformed answer payload: $payload');
        return;
      }

      debugPrint('Received Answer');
      final answerSession = RTCSessionDescription(sdp, type);
      await _peerConnection!.setRemoteDescription(answerSession);
    } catch (e) {
      debugPrint('Failed handling remote answer: $e');
      onError?.call('Failed to process call answer');
    }
  }

  Future<void> _handleReceiveIceCandidate(Map<String, dynamic> message) async {
    if (_isDisposed) return;

    try {
      final payload = message['payload'];
      if (_peerConnection == null || payload is! Map) return;

      final candidateValue = payload['candidate'];
      if (candidateValue is! String || candidateValue.isEmpty) {
        return;
      }

      final sdpMid = payload['sdpMid'] as String?;
      final sdpMLineIndex = payload['sdpMLineIndex'] as int?;

      final candidate = RTCIceCandidate(candidateValue, sdpMid, sdpMLineIndex);
      await _peerConnection!.addCandidate(candidate);
    } catch (e) {
      debugPrint('Failed handling ICE candidate: $e');
    }
  }

  void _handlePeerLeft(String peerId) {
    if (_isDisposed) return;

    // Current UI supports 1-on-1, so if remote leaves, reset state.
    debugPrint('Peer left: $peerId');
    remoteRenderer?.srcObject = null;

    _peerConnection?.close();
    _peerConnection = null;
  }

  Future<void> dispose() async {
    _isDisposed = true;
    _signaling.sendPeerLeft();
    _signaling.disconnect();

    remoteRenderer?.srcObject = null;
    localRenderer?.srcObject = null;
    await _localStream?.dispose();
    await _peerConnection?.dispose();
  }
}
