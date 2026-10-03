import 'package:flutter/material.dart';

import '../../services/pdf_edits.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass.dart';
import '../../widgets/text_dialog.dart';

/// The form's fields and the values typed or picked but not yet saved.
class FormController extends ChangeNotifier {
  FormController(this.fields);

  final List<PdfFormField> fields;
  final _text = <PdfFormField, String>{};
  final _checked = <PdfFormField, bool>{};
  final _option = <PdfFormField, int>{};

  /// Changes in the order they were made, for undo.
  final _history = <(PdfFormField, Object?)>[];

  bool get hasChanges => _text.isNotEmpty || _checked.isNotEmpty || _option.isNotEmpty;
  bool get canUndo => _history.isNotEmpty;

  Iterable<PdfFormField> onPage(int pageNumber) => fields.where((f) => f.pageNumber == pageNumber);

  String textOf(PdfFormField f) => _text[f] ?? f.value;
  bool checkedOf(PdfFormField f) => _checked[f] ?? f.checked;
  int optionOf(PdfFormField f) => _option[f] ?? f.selected;

  bool changed(PdfFormField f) => _text.containsKey(f) || _checked.containsKey(f) || _option.containsKey(f);

  /// Radio buttons that share [f]'s field name.
  Iterable<PdfFormField> _group(PdfFormField f) => fields.where((o) => o.kind == FormFieldKind.radio && o.name == f.name);

  void _remember(PdfFormField f) {
    final before = switch (f.kind) {
      FormFieldKind.text => _text[f],
      FormFieldKind.checkbox => _checked[f],
      FormFieldKind.choice => _option[f],
      // A radio change touches the whole group.
      FormFieldKind.radio => {for (final o in _group(f)) o: _checked[o]},
      FormFieldKind.other => null,
    };
    _history.add((f, before));
  }

  void setText(PdfFormField f, String value) {
    if (value == textOf(f)) return;
    _remember(f);
    if (value == f.value) {
      _text.remove(f);
    } else {
      _text[f] = value;
    }
    notifyListeners();
  }

  void toggle(PdfFormField f) {
    if (f.kind == FormFieldKind.checkbox) {
      _remember(f);
      final value = !checkedOf(f);
      if (value == f.checked) {
        _checked.remove(f);
      } else {
        _checked[f] = value;
      }
    } else if (f.kind == FormFieldKind.radio) {
      if (checkedOf(f)) return;
      _remember(f);
      for (final o in _group(f)) {
        final value = identical(o, f);
        if (value == o.checked) {
          _checked.remove(o);
        } else {
          _checked[o] = value;
        }
      }
    }
    notifyListeners();
  }

  void choose(PdfFormField f, int option) {
    if (option == optionOf(f)) return;
    _remember(f);
    if (option == f.selected) {
      _option.remove(f);
    } else {
      _option[f] = option;
    }
    notifyListeners();
  }

  void undo() {
    if (_history.isEmpty) return;
    final (f, before) = _history.removeLast();
    void restore<T>(Map<PdfFormField, T> map, PdfFormField key, T? value) => value == null ? map.remove(key) : map[key] = value;
    switch (f.kind) {
      case FormFieldKind.text:
        restore(_text, f, before as String?);
      case FormFieldKind.checkbox:
        restore(_checked, f, before as bool?);
      case FormFieldKind.choice:
        restore(_option, f, before as int?);
      case FormFieldKind.radio:
        for (final e in (before as Map<PdfFormField, bool?>).entries) {
          restore(_checked, e.key, e.value);
        }
      case FormFieldKind.other:
        break;
    }
    notifyListeners();
  }

  /// The changes as edits to write into the file.
  List<PdfEdit> toEdits() => [
        for (final e in _text.entries) FieldEdit(e.key.pageNumber, annotIndex: e.key.annotIndex, text: e.value),
        for (final e in _checked.entries)
          // Switching one radio button on switches the rest of its group off.
          if (e.key.kind == FormFieldKind.checkbox || e.value) FieldEdit(e.key.pageNumber, annotIndex: e.key.annotIndex, checked: e.value),
        for (final e in _option.entries) FieldEdit(e.key.pageNumber, annotIndex: e.key.annotIndex, option: e.value),
      ];
}

/// Tap targets over a page's fields, showing values not yet saved.
class FormLayer extends StatelessWidget {
  const FormLayer({super.key, required this.pageNumber, required this.pageSize, required this.controller, required this.onLocked});

  final int pageNumber;
  final Size pageSize;
  final FormController controller;
  final VoidCallback onLocked;

  Future<void> _edit(BuildContext context, PdfFormField f) async {
    if (f.readOnly) {
      onLocked();
      return;
    }
    switch (f.kind) {
      case FormFieldKind.text:
        final value = await showTextDialog(
          context,
          title: fieldTitle(f.name),
          initial: controller.textOf(f),
          multiline: f.multiline,
          fieldKey: const Key('form-text'),
        );
        if (value != null) controller.setText(f, value);
      case FormFieldKind.checkbox || FormFieldKind.radio:
        controller.toggle(f);
      case FormFieldKind.choice:
        final picked = await showGlassSheet<int>(context, (sheet) {
          final current = controller.optionOf(f);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(fieldTitle(f.name), style: Theme.of(sheet).textTheme.titleLarge),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.5),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (var i = 0; i < f.options.length; i++)
                      ListTile(
                        title: Text(f.options[i]),
                        trailing: i == current ? Icon(Icons.check_rounded, color: sheet.palette.accent) : null,
                        onTap: () => Navigator.pop(sheet, i),
                      ),
                  ],
                ),
              ),
            ],
          );
        });
        if (picked != null) controller.choose(f, picked);
      case FormFieldKind.other:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Stack(
        children: [
          for (final f in controller.onPage(pageNumber))
            Positioned(
              left: f.rect.left * pageSize.width,
              top: f.rect.top * pageSize.height,
              width: f.rect.width * pageSize.width,
              height: f.rect.height * pageSize.height,
              child: Semantics(
                button: true,
                label: fieldTitle(f.name),
                child: GestureDetector(
                  key: ValueKey('field-${f.pageNumber}-${f.annotIndex}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _edit(context, f),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: controller.changed(f) ? Colors.white : p.accent.withValues(alpha: f.readOnly ? 0.0 : 0.10),
                      border: Border.all(color: f.readOnly ? Colors.transparent : p.accent.withValues(alpha: 0.8), width: 1.2),
                    ),
                    child: controller.changed(f) ? _value(f) : null,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// A preview of an unsaved value; the saved file uses the field's own look.
  Widget _value(PdfFormField f) {
    final height = f.rect.height * pageSize.height;
    switch (f.kind) {
      case FormFieldKind.text || FormFieldKind.choice:
        final text = f.kind == FormFieldKind.text ? controller.textOf(f) : (controller.optionOf(f) >= 0 ? f.options[controller.optionOf(f)] : '');
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Align(
            alignment: f.multiline ? Alignment.topLeft : Alignment.centerLeft,
            child: Text(
              text,
              maxLines: f.multiline ? null : 1,
              overflow: TextOverflow.clip,
              style: TextStyle(color: Colors.black, fontSize: f.multiline ? (height / 5).clamp(5.0, 14.0) : (height * 0.62).clamp(5.0, 16.0), height: 1.1),
            ),
          ),
        );
      case FormFieldKind.checkbox:
        return controller.checkedOf(f) ? FittedBox(child: Icon(Icons.check_rounded, color: Colors.black)) : const SizedBox.expand();
      case FormFieldKind.radio:
        return controller.checkedOf(f) ? FittedBox(child: Icon(Icons.circle, color: Colors.black)) : const SizedBox.expand();
      case FormFieldKind.other:
        return const SizedBox.shrink();
    }
  }
}

/// "first_name" or "FirstName" reads as "First name".
String fieldTitle(String name) {
  final last = name.split('.').last;
  final spaced = last
      .replaceAll(RegExp(r'[_\-]+'), ' ')
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .trim()
      .toLowerCase();
  if (spaced.isEmpty) return 'Field';
  return spaced[0].toUpperCase() + spaced.substring(1);
}

/// Undo, cancel and save while filling in a form.
class FormBar extends StatelessWidget {
  const FormBar({super.key, required this.controller, required this.busy, required this.onCancel, required this.onSave});

  final FormController controller;
  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: GlassPanel(
          strong: true,
          radius: 26,
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Tap a field to fill it in, then save.',
                    textAlign: TextAlign.center, style: TextStyle(color: p.textMuted, fontSize: 13)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    IconButton(tooltip: 'Undo', onPressed: busy || !controller.canUndo ? null : controller.undo, icon: const Icon(Icons.undo_rounded)),
                    const SizedBox(width: 4),
                    Expanded(child: OutlinedButton(onPressed: busy ? null : onCancel, child: const Text('Cancel'))),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        key: const Key('save-form'),
                        onPressed: busy || !controller.hasChanges ? null : onSave,
                        child: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
