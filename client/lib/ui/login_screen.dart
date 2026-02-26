import 'package:flutter/material.dart';
import '../auth/session_manager.dart';
import '../auth/passkey_service.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final PasskeyService _passkeyService = PasskeyService();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _displayNameController = TextEditingController();
  
  bool _isLoading = true;
  bool _isRegistering = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _checkExistingSession();
  }

  Future<void> _checkExistingSession() async {
    final hasSession = await SessionManager.hasValidSession();
    if (hasSession && mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const HomeScreen()),
      );
    } else {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _handleLogin() async {
    final username = _usernameController.text.trim();
    if (username.isEmpty) {
      setState(() => _errorMessage = 'Please enter a username');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    final success = await _passkeyService.login(username);
    
    if (mounted) {
      if (success) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const HomeScreen()),
        );
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Login failed. If you have not registered on this device, please do so first.';
        });
      }
    }
  }

  Future<void> _handleRegister() async {
    final username = _usernameController.text.trim();
    final displayName = _displayNameController.text.trim();
    
    if (username.isEmpty || displayName.isEmpty) {
      setState(() => _errorMessage = 'Please enter both username and display name');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    final success = await _passkeyService.register(username, displayName);
    
    if (mounted) {
      setState(() {
        _isLoading = false;
        if (success) {
          _isRegistering = false; // Switch to login after successful registration
          _errorMessage = 'Registration successful! You can now log in.';
        } else {
          _errorMessage = 'Registration failed. Please try again.';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Huddle Security'),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.fingerprint, size: 80, color: Colors.deepPurple),
              const SizedBox(height: 32),
              Text(
                _isRegistering ? 'Register New Device' : 'Secure Login',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Passwordless authentication powered by Passkeys',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              
              if (_errorMessage.isNotEmpty) ...[
                Text(
                  _errorMessage,
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
              ],

              TextField(
                controller: _usernameController,
                decoration: InputDecoration(
                  labelText: 'Username',
                  border: const OutlineInputBorder(),
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  prefixIcon: const Icon(Icons.person),
                ),
              ),
              
              if (_isRegistering) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _displayNameController,
                  decoration: InputDecoration(
                    labelText: 'Display Name',
                    border: const OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.grey.shade100,
                    prefixIcon: const Icon(Icons.badge),
                  ),
                ),
              ],
              
              const SizedBox(height: 24),
              
              FilledButton.icon(
                icon: const Icon(Icons.key),
                label: Text(_isRegistering ? 'Register Passkey' : 'Login with Passkey'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                ),
                onPressed: _isRegistering ? _handleRegister : _handleLogin,
              ),
              
              const SizedBox(height: 16),
              
              TextButton(
                onPressed: () {
                  setState(() {
                    _isRegistering = !_isRegistering;
                    _errorMessage = '';
                  });
                },
                child: Text(_isRegistering 
                  ? 'Already registered? Login instead' 
                  : 'New device? Register first'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
