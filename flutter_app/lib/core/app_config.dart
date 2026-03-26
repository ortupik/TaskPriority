/// Central constants for FieldPulse app.
/// In production, configure BASE_URL via --dart-define at build time:
///   flutter run --dart-define=BASE_URL=https://api.yourdomain.com
library;

class AppConfig {
  AppConfig._();

  static const String baseUrl = String.fromEnvironment(
    'BASE_URL',
    defaultValue: 'http://10.0.2.2:8000', // Android emulator → host
  );

  static const String apiPrefix = '/api/v1';
  static String get apiBase => '$baseUrl$apiPrefix';

  // Token lifetimes (must match backend JWT_SETTINGS)
  static const int accessTokenLifetimeSecs = 15 * 60; // 15 min
  static const int refreshTokenLifetimeDays = 7;

  // Pagination
  static const int jobPageSize = 20;

  // Photo
  static const int photoMaxLongestEdgePx = 1200;
  static const int photoJpegQuality = 80;

  // Sync
  static const Duration syncDebounce = Duration(seconds: 3);
  static const int photoUploadMaxRetries = 3;

  // UI
  static const Duration snackbarDuration = Duration(seconds: 4);
}
