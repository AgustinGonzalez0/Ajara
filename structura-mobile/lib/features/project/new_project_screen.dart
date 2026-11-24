import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../data/project_models.dart';
import '../../widgets/common.dart';

class NewProjectScreen extends ConsumerStatefulWidget {
  const NewProjectScreen({super.key});
  @override
  ConsumerState<NewProjectScreen> createState() => _NewProjectScreenState();
}

class _NewProjectScreenState extends ConsumerState<NewProjectScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _desc = TextEditingController();
  var _type = BuildingType.unspecified;
  var _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _create({required bool thenImport, bool photo = false}) async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final m = await ref.read(projectsProvider.notifier).create(_name.text, _desc.text, _type);
      if (!mounted) return;
      context.pushReplacement(photo ? Routes.photo(m.id) : (thenImport ? Routes.import(m.id) : Routes.project(m.id)));
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo crear el proyecto: $e')));
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final importFirst = GoRouterState.of(context).uri.queryParameters['import'] == '1';
    final photoFirst = GoRouterState.of(context).uri.queryParameters['photo'] == '1';
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Nuevo proyecto')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Form(
              key: _form,
              child: ListView(padding: const EdgeInsets.all(Gap.xl), children: [
                TextFormField(
                  key: const Key('project_name'),
                  controller: _name,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: 'Nombre del proyecto', hintText: 'Ej.: Vivienda Martínez'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Ingresá un nombre' : null,
                ),
                const SizedBox(height: Gap.lg),
                TextFormField(
                  controller: _desc,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Descripción (opcional)'),
                ),
                const SectionLabel('Tipo de construcción'),
                Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                  for (final b in BuildingType.values)
                    ChoiceChip(
                      label: Text(b.label),
                      selected: _type == b,
                      onSelected: (_) => setState(() => _type = b),
                    ),
                ]),
                const SizedBox(height: Gap.sm),
                Text('El tipo se usa para organizar proyectos. No modifica el análisis.',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                const SizedBox(height: Gap.xxl),
                FilledButton.icon(
                  key: const Key('create_and_photo'),
                  onPressed: _saving ? null : () => _create(thenImport: false, photo: true),
                  icon: const Icon(Icons.photo_camera_rounded),
                  label: const Text('Crear y fotografiar plano'),
                ),
                const SizedBox(height: Gap.md),
                if (!photoFirst) FilledButton.tonalIcon(
                  key: const Key('create_and_import'),
                  onPressed: _saving ? null : () => _create(thenImport: true),
                  icon: const Icon(Icons.upload_file_rounded),
                  label: const Text('Crear e importar plano'),
                ),
                const SizedBox(height: Gap.md),
                if (!importFirst)
                  OutlinedButton(
                    key: const Key('create_only'),
                    onPressed: _saving ? null : () => _create(thenImport: false),
                    child: const Text('Crear sin plano'),
                  ),
                if (_saving) const Padding(padding: EdgeInsets.only(top: Gap.lg), child: LinearProgressIndicator(color: StructuraColors.accent)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
