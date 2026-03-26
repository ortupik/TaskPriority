import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'features/auth/auth_provider.dart';
import 'features/jobs/job_list_screen.dart';
import 'features/jobs/job_detail_screen.dart';
import 'features/checklist/checklist_screen.dart';

part 'app_router.g.dart';

@riverpod
GoRouter router(Ref ref) {
  final authState = ref.watch(authProvider);

  return GoRouter(
    debugLogDiagnostics: false,
    redirect: (context, state) {
      final isAuth = authState is AuthAuthenticated;
      final isLoggingIn = state.matchedLocation == '/login';

      if (!isAuth && !isLoggingIn) return '/login';
      if (isAuth && isLoggingIn) return '/jobs';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/jobs',
        builder: (_, __) => const JobListScreen(),
        routes: [
          GoRoute(
            path: ':id',
            builder: (_, state) => JobDetailScreen(
              jobId: state.pathParameters['id']!,
            ),
            routes: [
              GoRoute(
                path: 'checklist',
                builder: (context, state) {
                  final jobId = state.pathParameters['id']!;
                  // Schema passed via extra
                  final schema = state.extra as Map<String, dynamic>? ?? {};
                  return ChecklistScreen(jobId: jobId, schema: schema);
                },
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

// ── App entry ──────────────────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: FieldPulseApp()));
}

class FieldPulseApp extends ConsumerWidget {
  const FieldPulseApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'FieldPulse',
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      routerConfig: router,
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final seed = const Color(0xFF1565C0); // deep blue

    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: brightness,
      ),
      cardTheme: const CardTheme(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        scrolledUnderElevation: 2,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }
}
