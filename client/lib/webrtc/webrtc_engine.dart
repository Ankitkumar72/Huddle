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
  int _discoveredWidth = 1280; // Default fallback candidate
  int _discoveredHeight = 720;

  // UI callbacks
  Function()? onLocalStreamReady;
  Function()? onRemoteStreamReady;
  Function(String)? onError;

  WebRtcEngine({required SignalingService signaling}) : _signaling = signaling;

  Future<void> initialize(
    RTCVideoRenderer local,
    RTCVideoRenderer remote,
  ) async {
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
    final List<Map<String, int>> qualityTiers = [
      {'width': 1920, 'height': 1080},
      {'width': 1280, 'height': 720},
      {'width': 640, 'height': 480},
    ];

    for (var tier in qualityTiers) {
      try {
        final width = tier['width']!;
        final height = tier['height']!;
        debugPrint('Probing camera capability: ${width}x$height @ 30fps');

        final constraints = <String, dynamic>{
          'audio': {
            'echoCancellation': true,
            'noiseSuppression': true,
            'autoGainControl': true,
          },
          'video': {
            'facingMode': 'user',
            'width': {'ideal': width},
            'height': {'ideal': height},
            'frameRate': {'ideal': 30},
          },
        };

        _localStream = await navigator.mediaDevices.getUserMedia(constraints);

        // Success! Record the actual resolution
        _discoveredWidth = width;
        _discoveredHeight = height;
        debugPrint(
          'Successfully opened camera at $_discoveredWidth x $_discoveredHeight',
        );

        localRenderer?.srcObject = _localStream;
        onLocalStreamReady?.call();
        return; // Exit loop on success
      } catch (e) {
        debugPrint(
          'Failed to open camera at ${tier['width']}x${tier['height']}: $e',
        );
        // Continue to next lower tier
      }
    }

    // If all tiers fail
    onError?.call(
      'Could not access camera/microphone at any supported quality',
    );
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
        'bundlePolicy': 'max-bundle',
        'rtcpMuxPolicy': 'require',
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
      final sdp = _optimizeSdp(offer.sdp!);
      final optimizedOffer = RTCSessionDescription(sdp, offer.type);
      await pc.setLocalDescription(optimizedOffer);

      _signaling.sendOffer(peerId, {
        'sdp': optimizedOffer.sdp,
        'type': optimizedOffer.type,
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
      final sdpOptimized = _optimizeSdp(answer.sdp!);
      final optimizedAnswer = RTCSessionDescription(sdpOptimized, answer.type);
      await pc.setLocalDescription(optimizedAnswer);

      _signaling.sendAnswer(senderId, {
        'sdp': optimizedAnswer.sdp,
        'type': optimizedAnswer.type,
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

  String _optimizeSdp(String sdp) {
    // 1. Prefer Opus with low packet time (10ms instead of default 20ms)
    // 2. Add x-google-min-bitrate to prevent initial video lag
    List<String> lines = sdp.split('\r\n');
    List<String> optimized = [];

    for (var line in lines) {
      optimized.add(line);
      if (line.startsWith('a=rtpmap:') && line.contains('opus/48000/2')) {
        optimized.add(
          'a=fmtp:${line.split(' ')[0].split(':')[1]} minptime=10;useinbandfec=1',
        );
      }
      if (line.startsWith('a=mid:video')) {
        // Dynamic Bitrate Scaling based on discovered quality
        int maxBitrate = 1500;
        int minBitrate = 500;
        int startBitrate = 800;

        if (_discoveredHeight >= 1080) {
          maxBitrate = 8000;
          minBitrate = 2000;
          startBitrate = 5000;
        } else if (_discoveredHeight >= 720) {
          maxBitrate = 4000;
          minBitrate = 1000;
          startBitrate = 2500;
        }

        optimized.add('b=AS:$maxBitrate');
        optimized.add(
          'a=fmtp:96 x-google-min-bitrate=$minBitrate;x-google-max-bitrate=$maxBitrate;x-google-start-bitrate=$startBitrate',
        );
      }
    }

    return optimized.join('\r\n');
  }
}
