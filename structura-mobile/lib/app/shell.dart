import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'router.dart';

/// Navegación principal adaptativa: barra inferior en pantallas compactas,
/// rail lateral en pantallas anchas (tablet / plegable / horizontal).
class AppShell extends StatelessWidget {
  final String location;
  final Widget child;
  const AppShell({super.key, required this.location, required this.child});

  static const _destinations = [
    (Routes.home, Icons.space_dashboard_outlined, Icons.space_dashboard_rounded, 'Proyectos'),
    (Routes.settings, Icons.tune_outlined, Icons.tune_rounded, 'Configuración'),
  ];

  int get _index => location.startsWith(Routes.settings) ? 1 : 0;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    void go(int i) => context.go(_destinations[i].$1);
    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: go,
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: _Mark(),
            ),
            destinations: [
              for (final d in _destinations)
                NavigationRailDestination(icon: Icon(d.$2), selectedIcon: Icon(d.$3), label: Text(d.$4)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ]),
      );
    }
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: go,
        destinations: [
          for (final d in _destinations) NavigationDestination(icon: Icon(d.$2), selectedIcon: Icon(d.$3), label: d.$4),
        ],
      ),
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark();
  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Theme.of(context).colorScheme.primary, width: 1.5),
        ),
        child: Center(
          child: Text('S', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700, fontSize: 18)),
        ),
      );
}
