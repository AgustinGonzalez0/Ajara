import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/analysis/analysis_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/editor2d/editor_screen.dart';
import '../features/import/import_screen.dart';
import '../features/model3d/model_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/photo/photo_screen.dart';
import '../features/project/new_project_screen.dart';
import '../features/project/project_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/simulation/calibrate_screen.dart';
import '../features/simulation/simulation_screen.dart';
import '../features/splash/splash_screen.dart';
import 'shell.dart';

abstract final class Routes {
  static const splash = '/';
  static const onboarding = '/onboarding';
  static const home = '/home';
  static const settings = '/settings';
  static const newProject = '/projects/new';
  static String project(String id) => '/projects/$id';
  static String import(String id, {bool auto = false, bool quick = false}) =>
      '/projects/$id/import${_q({'auto': auto, 'quick': quick})}';
  static String editor(String id) => '/projects/$id/editor';
  static String analysis(String id) => '/projects/$id/analysis';
  static String model3d(String id) => '/projects/$id/model';
  static String photo(String id, {bool camera = true, bool quick = false}) =>
      '/projects/$id/photo?source=${camera ? 'camera' : 'gallery'}${quick ? '&quick=1' : ''}';
  static String simulate(String id) => '/projects/$id/simulate';
  static String calibrate(String id, {bool thenSimulate = false}) =>
      '/projects/$id/calibrate${thenSimulate ? '?next=simulate' : ''}';
  static String model3dHazard(String id, String hazard) => '/projects/$id/model?hazard=$hazard';

  static String _q(Map<String, bool> flags) {
    final on = [for (final e in flags.entries) if (e.value) '${e.key}=1'];
    return on.isEmpty ? '' : '?${on.join('&')}';
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: Routes.splash,
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const SplashScreen()),
      GoRoute(path: Routes.onboarding, builder: (_, _) => const OnboardingScreen()),
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(path: Routes.home, pageBuilder: (_, _) => const NoTransitionPage(child: DashboardScreen())),
          GoRoute(path: Routes.settings, pageBuilder: (_, _) => const NoTransitionPage(child: SettingsScreen())),
        ],
      ),
      GoRoute(path: Routes.newProject, builder: (_, _) => const NewProjectScreen()),
      GoRoute(
        path: '/projects/:id',
        builder: (_, s) => ProjectScreen(projectId: s.pathParameters['id']!),
        routes: [
          GoRoute(
              path: 'import',
              builder: (_, s) => ImportScreen(
                  projectId: s.pathParameters['id']!,
                  autoPick: s.uri.queryParameters['auto'] == '1',
                  quick: s.uri.queryParameters['quick'] == '1')),
          GoRoute(path: 'editor', builder: (_, s) => EditorScreen(projectId: s.pathParameters['id']!)),
          GoRoute(path: 'analysis', builder: (_, s) => AnalysisScreen(projectId: s.pathParameters['id']!)),
          GoRoute(
              path: 'model',
              builder: (_, s) => ModelScreen(projectId: s.pathParameters['id']!, hazard: s.uri.queryParameters['hazard'])),
          GoRoute(
              path: 'photo',
              builder: (_, s) => PhotoScreen(
                  projectId: s.pathParameters['id']!,
                  camera: s.uri.queryParameters['source'] != 'gallery',
                  quick: s.uri.queryParameters['quick'] == '1')),
          GoRoute(path: 'simulate', builder: (_, s) => SimulationScreen(projectId: s.pathParameters['id']!)),
          GoRoute(
              path: 'calibrate',
              builder: (_, s) => CalibrateScreen(
                  projectId: s.pathParameters['id']!, thenSimulate: s.uri.queryParameters['next'] == 'simulate')),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('Ruta no encontrada')),
      body: Center(child: Text('${state.uri}')),
    ),
  );
});
