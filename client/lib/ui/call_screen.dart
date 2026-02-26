import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../signaling/signaling_service.dart';
import '../webrtc/webrtc_engine.dart';

class CallScreen extends StatefulWidget {
  final String roomCode;

  const CallScreen({super.key, required this.roomCode});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late WebRtcEngine _engine;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  bool _isEngineReady = false;

  @override
  void initState() {
    super.initState();
    _initEngine();
  }

  Future<void> _initEngine() async {
    // 1. Initialize Renderers
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    final signalingUrl =
        (dotenv.env['SIGNALING_URL'] ?? 'ws://127.0.0.1:8080').trim();

    // 2. Setup SignalingService pointing to local/LAN/tunnel signaling server
    final signaling = SignalingService(
      url: signalingUrl,
      room: widget.roomCode,
    );

    // 3. Initialize Engine
    _engine = WebRtcEngine(signaling: signaling);
    
    _engine.onLocalStreamReady = () {
      if (mounted) setState(() {});
    };
    
    _engine.onRemoteStreamReady = () {
      if (mounted) setState(() {});
    };
    
    _engine.onError = (error) {
       if (!mounted) return;
       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    };

    await _engine.initialize(_localRenderer, _remoteRenderer);
    
    if (mounted) {
      setState(() => _isEngineReady = true);
    }
  }

  @override
  void dispose() {
    _engine.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isEngineReady) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Full Screen Remote Renderer
          Positioned.fill(
            child: _remoteRenderer.srcObject != null
                ? RTCVideoView(
                    _remoteRenderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  )
                : const Center(
                    child: Text(
                      'Waiting for someone to join...',
                      style: TextStyle(color: Colors.white70, fontSize: 18),
                    ),
                  ),
          ),
          
          // 2. Top App Bar overlay
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: Colors.black54,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    Text(
                      'Code: ${widget.roomCode}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(width: 48), // Balance for centering
                  ],
                ),
              ),
            ),
          ),

          // 3. Picture-in-picture Local View (Draggable)
          if (_localRenderer.srcObject != null)
            Positioned(
              right: 20,
              bottom: 40,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  width: 120,
                  height: 160,
                  color: Colors.black,
                  child: RTCVideoView(
                    _localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
