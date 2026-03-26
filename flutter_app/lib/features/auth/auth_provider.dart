import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/network/api_client.dart';
import '../../core/storage/token_storage.dart';

part 'auth_provider.g.dart';

// ── Auth state ────────────────────────────────────────────────────────────

class AuthUser {
  final String id;
  final String email;
  final String fullName;
  final String role;

  const AuthUser({
    required this.id,
    required this.email,
    required this.fullName,
    required this.role,
  });
}

sealed class AuthState {}

class AuthInitial extends AuthState {}

class AuthLoading extends AuthState {}

class AuthAuthenticated extends AuthState {
  final AuthUser user;
  AuthAuthenticated(this.user);
}

class AuthUnauthenticated extends AuthState {}

class AuthError extends AuthState {
  final String message;
  AuthError(this.message);
}

@riverpod
class Auth extends _$Auth {
  @override
  AuthState build() {
    _checkExistingSession();
    return AuthInitial();
  }

  Future<void> _checkExistingSession() async {
    try {
      final storage = ref.read(tokenStorageProvider);
      final hasSession = await storage.hasValidSession();
      if (!hasSession) {
        state = AuthUnauthenticated();
        return;
      }
      final id = await storage.getUserId();
      final email = await storage.getUserEmail();
      final name = await storage.getUserName();
      final role = await storage.getUserRole();
      if (id != null && email != null) {
        state = AuthAuthenticated(AuthUser(
          id: id,
          email: email,
          fullName: name ?? '',
          role: role ?? 'technician',
        ));
      } else {
        state = AuthUnauthenticated();
      }
    } catch (e) {
      // If session check fails for any reason, treat as unauthenticated
      // rather than leaving the app in AuthInitial forever
      debugPrint('_checkExistingSession error: $e');
      state = AuthUnauthenticated();
    }
  }

  Future<void> login(String email, String password) async {
    state = AuthLoading();
    try {
      final api = ref.read(apiClientProvider);
      final resp = await api.post('/auth/login/', data: {
        'email': email.trim().toLowerCase(),
        'password': password,
        'device_info': 'Flutter App',
      });

      // ── Debug: log the raw response shape so field-name mismatches are
      //    immediately visible in the console (safe to remove in production)
      debugPrint('LOGIN RESPONSE TYPE: ${resp.data.runtimeType}');
      debugPrint('LOGIN RESPONSE: ${resp.data}');

      // ── Safe extraction — hard casts like `resp.data as Map` throw a
      //    TypeError that crashes the app even inside a try/catch if the
      //    response shape differs from expectations ────────────────────────
      final rawData = resp.data;
      if (rawData == null) {
        state = AuthError('Empty response from server.');
        return;
      }

      final data = rawData is Map
          ? Map<String, dynamic>.from(rawData)
          : <String, dynamic>{};

      // Support both DRF Simple JWT ('access'/'refresh') and custom key names
      final accessToken = (data['access_token'] ?? data['access'])?.toString();
      final refreshToken =
          (data['refresh_token'] ?? data['refresh'])?.toString();

      if (accessToken == null || refreshToken == null) {
        state = AuthError('Malformed auth response — missing tokens.\n'
            'Keys received: ${data.keys.toList()}');
        return;
      }

      final storage = ref.read(tokenStorageProvider);
      await storage.saveTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
      );

      final rawUser = data['user'];
      if (rawUser == null) {
        state = AuthError('Malformed auth response — missing user object.\n'
            'Keys received: ${data.keys.toList()}');
        return;
      }

      final user = rawUser is Map
          ? Map<String, dynamic>.from(rawUser)
          : <String, dynamic>{};

      // Use .toString() for id — servers sometimes return int IDs, not strings
      final userId = user['id']?.toString() ?? '';
      final userEmail = (user['email'] ?? email).toString();
      // Support both snake_case and camelCase naming conventions
      final fullName =
          (user['full_name'] ?? user['fullName'] ?? user['name'] ?? '')
              .toString();
      final role = (user['role'] ?? 'technician').toString();

      if (userId.isEmpty) {
        state = AuthError('Malformed auth response — missing user id.\n'
            'User keys received: ${user.keys.toList()}');
        return;
      }

      await storage.saveUserInfo(
        id: userId,
        email: userEmail,
        fullName: fullName,
        role: role,
      );

      state = AuthAuthenticated(AuthUser(
        id: userId,
        email: userEmail,
        fullName: fullName,
        role: role,
      ));
    } catch (e) {
      debugPrint('LOGIN ERROR: $e');
      state = AuthError(e is DioException ? parseApiError(e) : e.toString());
    }
  }

  Future<bool> tryBiometricUnlock() async {
    try {
      final storage = ref.read(tokenStorageProvider);
      final hasSession = await storage.hasValidSession();
      if (!hasSession) return false;

      final auth = LocalAuthentication();
      final canCheck = await auth.canCheckBiometrics;
      if (!canCheck) return false;

      final didAuth = await auth.authenticate(
        localizedReason: 'Unlock FieldPulse',
        options: const AuthenticationOptions(biometricOnly: true),
      );
      if (!didAuth) return false;

      await _checkExistingSession();
      return state is AuthAuthenticated;
    } catch (e) {
      debugPrint('BIOMETRIC ERROR: $e');
      return false;
    }
  }

  Future<void> logout() async {
    try {
      final api = ref.read(apiClientProvider);
      await api.post('/auth/logout/');
    } catch (_) {}
    try {
      final storage = ref.read(tokenStorageProvider);
      await storage.clearAll();
    } catch (e) {
      debugPrint('LOGOUT CLEAR ERROR: $e');
    }
    state = AuthUnauthenticated();
  }
}

// ── Login Screen ──────────────────────────────────────────────────────────

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailCtrl = TextEditingController(text: 'tech1@fieldpulse.dev');
  final _passwordCtrl = TextEditingController(text: 'techie123');

  final _formKey = GlobalKey<FormState>();
  bool _obscure = true;
  bool _canUseBiometric = true;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  Future<void> _checkBiometric() async {
    try {
      final storage = ref.read(tokenStorageProvider);
      final hasSession = await storage.hasValidSession();
      if (!hasSession) return;
      final auth = LocalAuthentication();
      final can = await auth.canCheckBiometrics;
      if (mounted) setState(() => _canUseBiometric = can);
    } catch (e) {
      debugPrint('BIOMETRIC CHECK ERROR: $e');
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    await ref.read(authProvider.notifier).login(
          _emailCtrl.text,
          _passwordCtrl.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final isLoading = authState is AuthLoading;

    ref.listen(authProvider, (_, next) {
      if (next is AuthError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(next.message), backgroundColor: Colors.red),
        );
      }
    });

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 40),
                  // Logo / wordmark
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.bolt,
                            color: Colors.white, size: 28),
                      ),
                      const SizedBox(width: 12),
                      Text('FieldPulse',
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                              )),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text('Field Service Management',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.outline,
                            )),
                  ),
                  const SizedBox(height: 48),
                  TextFormField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Email is required';
                      if (!v.contains('@')) return 'Enter a valid email';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordCtrl,
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outlined),
                      suffixIcon: IconButton(
                        icon: Icon(_obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Password is required';
                      if (v.length < 8) return 'At least 8 characters';
                      return null;
                    },
                  ),
                  const SizedBox(height: 32),
                  FilledButton(
                    onPressed: isLoading ? null : _submit,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    child: isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Sign In', style: TextStyle(fontSize: 16)),
                  ),
                  if (_canUseBiometric) ...[
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final ok = await ref
                            .read(authProvider.notifier)
                            .tryBiometricUnlock();
                        if (!ok && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content:
                                    Text('Biometric authentication failed')),
                          );
                        }
                      },
                      icon: const Icon(Icons.fingerprint),
                      label: const Text('Use Biometrics'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
