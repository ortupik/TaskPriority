import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'token_storage.g.dart';

@riverpod
TokenStorage tokenStorage(Ref ref) => TokenStorage();

const _kAccessToken = 'access_token';
const _kRefreshToken = 'refresh_token';
const _kUserId = 'user_id';
const _kUserEmail = 'user_email';
const _kUserName = 'user_name';
const _kUserRole = 'user_role';

class TokenStorage {
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _storage.write(key: _kAccessToken, value: accessToken);
    await _storage.write(key: _kRefreshToken, value: refreshToken);
  }

  Future<void> saveUserInfo({
    required String id,
    required String email,
    required String fullName,
    required String role,
  }) async {
    await _storage.write(key: _kUserId, value: id);
    await _storage.write(key: _kUserEmail, value: email);
    await _storage.write(key: _kUserName, value: fullName);
    await _storage.write(key: _kUserRole, value: role);
  }

  Future<String?> getAccessToken() => _storage.read(key: _kAccessToken);
  Future<String?> getRefreshToken() => _storage.read(key: _kRefreshToken);
  Future<String?> getUserId() => _storage.read(key: _kUserId);
  Future<String?> getUserEmail() => _storage.read(key: _kUserEmail);
  Future<String?> getUserName() => _storage.read(key: _kUserName);
  Future<String?> getUserRole() => _storage.read(key: _kUserRole);

  Future<bool> hasValidSession() async {
    final refresh = await getRefreshToken();
    return refresh != null && refresh.isNotEmpty;
  }

  Future<void> clearAll() async {
    await _storage.deleteAll();
  }
}
