import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  final support = await getApplicationSupportDirectory();
  final dirs = AppDirs(
    projects: Directory(p.join(docs.path, 'structura', 'projects')),
    models: Directory(p.join(support.path, 'models')),
  );
  await dirs.projects.create(recursive: true);
  final prefs = await SharedPreferences.getInstance();
  runApp(ProviderScope(
    overrides: [
      appDirsProvider.overrideWithValue(dirs),
      prefsProvider.overrideWithValue(prefs),
    ],
    child: const StructuraApp(),
  ));
}
