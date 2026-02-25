import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../signaling/signaling_service.dart';

class WebRtcEngine {
  final SignalingService _signaling;
  final String _roomCode;
  
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  RTCVideoRenderer? localRenderer;
  RTCVideoRenderer? remoteRenderer;
  
  bool _isDisposed = false;

  // UI callbacks
  Function()? onLocalStreamReady;
  Function()? onRemoteStreamReady;
  Function(String)? onError;

  WebRtcEngine({required SignalingService signaling, required String roomCode})
      : _signaling = signaling,
        _roomCode = roomCode;

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
    _signaling.connect();
  }

  Future<void> _openUserMedia() async {
    try {
      final Map<String, dynamic> mediaConstraints = {
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
    if (_peerConnection != null) return;

    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        // Note: Add TURN server here if strict NAT traversal is required.
      ],
      'sdpSemantics': 'unified-plan'
    };

    _peerConnection = await createPeerConnection(config);

    // Add local tracks to peer connection
    _localStream?.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });

    // Handle remote stream
    _peerConnection!.onTrack = (event) {
      if (event.track.kind == 'video') {
        remoteRenderer?.srcObject = event.streams[0];
        onRemoteStreamReady?.call();
      }
    };

    // Handle outgoing ICE candidates
    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        _signaling.sendIceCandidate('*', { // '*' sends to all peers in the room
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      }
    };

    _peerConnection!.onConnectionState = (state) {
      debugPrint('Connection state changed: $state');
    };
  }

  // ---- Signaling Handshake Logic ----

  Future<void> _handlePeerJoined(String peerId) async {
    debugPrint('Peer joined: $peerId. Initiating handshake...');
    await _createPeerConnection();

    // The existing user creates the offer
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);

    _signaling.sendOffer(peerId, {
      'sdp': offer.sdp,
      'type': offer.type,
    });
  }

  Future<void> _handleReceiveOffer(Map<String, dynamic> message) async {
    final senderId = message['senderId'];
    final payload = message['payload'];
    
    debugPrint('Received Offer from: $senderId');
    await _createPeerConnection();

    final offerSession = RTCSessionDescription(payload['sdp'], payload['type']);
    await _peerConnection!.setRemoteDescription(offerSession);

    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    _signaling.sendAnswer(senderId, {
      'sdp': answer.sdp,
      'type': answer.type,
    });
  }

  Future<void> _handleReceiveAnswer(Map<String, dynamic> message) async {
    final payload = message['payload'];
    debugPrint('Received Answer');

    if (_peerConnection == null) return;

    final answerSession = RTCSessionDescription(payload['sdp'], payload['type']);
    await _peerConnection!.setRemoteDescription(answerSession);
  }

  Future<void> _handleReceiveIceCandidate(Map<String, dynamic> message) async {
    final payload = message['payload'];
    
    if (_peerConnection == null) return;

    final candidate = RTCIceCandidate(
      payload['candidate'],
      payload['sdpMid'],
      payload['sdpMLineIndex'],
    );
    await _peerConnection!.addCandidate(candidate);
  }

  void _handlePeerLeft(String peerId) {
    // Phase 3 supports 1-on-1, so if the other person leaves, close connection
    debugPrint('Peer left: $peerId');
    remoteRenderer?.srcObject = null;
    
    // Reset connection state for future joins
    _peerConnection?.close();
    _peerConnection = null;
  }

  Future<void> dispose() async {
    _isDisposed = true;
    _signaling.sendPeerLeft();
    _signaling.disconnect();
    
    await _localStream?.dispose();
    await _peerConnection?.dispose();
    remoteRenderer?.srcObject = null;
    localRenderer?.srcObject = null;
  }
}
