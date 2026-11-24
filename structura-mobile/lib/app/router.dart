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
  static String import(String id) => '/projects/$id/import';
  static String editor(String id) => '/projects/$id/editor';
  static String analysis(String id) => '/projects/$id/analysis';
  static String model3d(String id) => '/projects/$id/model';
  static String photo(String id, {bool camera = true}) => '/projects/$id/photo?source=${camera ? 'camera' : 'gallery'}';
  static String simulate(String id) => '/projects/$id/simulate';
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
          GoRoute(path: 'import', builder: (_, s) => ImportScreen(projectId: s.pathParameters['id']!)),
          GoRoute(path: 'editor', builder: (_, s) => EditorScreen(projectId: s.pathParameters['id']!)),
          GoRoute(path: 'analysis', builder: (_, s) => AnalysisScreen(projectId: s.pathParameters['id']!)),
          GoRoute(
              path: 'model',
              builder: (_, s) => ModelScreen(projectId: s.pathParameters['id']!, hazard: s.uri.queryParameters['hazard'])),
          GoRoute(
              path: 'photo',
              builder: (_, s) => PhotoScreen(
                  projectId: s.pathParameters['id']!, camera: s.uri.queryParameters['source'] != 'gallery')),
          GoRoute(path: 'simulate', builder: (_, s) => SimulationScreen(projectId: s.pathParameters['id']!)),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('Ruta no encontrada')),
      body: Center(child: Text('${state.uri}')),
    ),
  );
});
