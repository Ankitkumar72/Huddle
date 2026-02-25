import 'dart:math';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'call_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _roomController = TextEditingController();
  bool _isLoading = false;

  String _generateRoomCode() {
    final random = Random();
    // Generate a 6-digit random code
    final code = (random.nextInt(900000) + 100000).toString();
    return code;
  }

  Future<void> _startOrJoinCall(String roomCode) async {
    if (roomCode.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid room code')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    // Request permissions
    final cameraStatus = await Permission.camera.request();
    final micStatus = await Permission.microphone.request();

    if (!mounted) return;

    if (cameraStatus.isGranted && micStatus.isGranted) {
      setState(() {
        _isLoading = false;
      });
      // Navigate to Call Screen
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => CallScreen(roomCode: roomCode),
        ),
      );
    } else {
      setState(() {
        _isLoading = false;
      });
      _showPermissionDeniedDialog();
    }
  }

  void _showPermissionDeniedDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permissions Required'),
        content: const Text(
          'Huddle needs camera and microphone access to make video calls. '
          'Please grant them in your device settings to continue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Huddle'),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.video_call, size: 80, color: Colors.deepPurple),
              const SizedBox(height: 32),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Start a New Call', style: TextStyle(fontSize: 16)),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                ),
                onPressed: _isLoading ? null : () {
                  final newCode = _generateRoomCode();
                  // In a real app we might want to auto-copy to clipboard here
                  _startOrJoinCall(newCode);
                },
              ),
              const SizedBox(height: 32),
              const Center(
                child: Text('OR', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _roomController,
                decoration: InputDecoration(
                  labelText: 'Enter Room Code',
                  hintText: 'e.g. 123456',
                  border: const OutlineInputBorder(),
                  filled: true,
                  fillColor: Colors.grey.shade100,
                ),
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, letterSpacing: 8),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.login),
                label: const Text('Join Call', style: TextStyle(fontSize: 16)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                ),
                onPressed: _isLoading ? null : () {
                  _startOrJoinCall(_roomController.text.trim());
                },
              ),
              if (_isLoading) ...[
                const SizedBox(height: 32),
                const Center(child: CircularProgressIndicator()),
              ]
            ],
          ),
        ),
      ),
    );
  }
}
