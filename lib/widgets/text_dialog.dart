import 'package:flutter/material.dart';

/// Asks for a line or block of text. Returns null when cancelled.
///
/// [validate] returns an error to show under the field, or null to accept.
Future<String?> showTextDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hint,
  bool multiline = false,
  int? maxLength,
  String? Function(String text)? validate,
  Key? fieldKey,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextDialog(title: title, initial: initial, hint: hint, multiline: multiline, maxLength: maxLength, validate: validate, fieldKey: fieldKey),
  );
}

// The dialog owns its controller so it lives until the closing animation ends.
class _TextDialog extends StatefulWidget {
  const _TextDialog({required this.title, required this.initial, this.hint, required this.multiline, this.maxLength, this.validate, this.fieldKey});

  final String title;
  final String initial;
  final String? hint;
  final bool multiline;
  final int? maxLength;
  final String? Function(String text)? validate;
  final Key? fieldKey;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final error = widget.validate?.call(_controller.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, _controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: widget.fieldKey,
        controller: _controller,
        autofocus: true,
        maxLength: widget.maxLength,
        maxLines: widget.multiline ? null : 1,
        minLines: widget.multiline ? 3 : 1,
        keyboardType: widget.multiline ? TextInputType.multiline : TextInputType.text,
        decoration: InputDecoration(hintText: widget.hint, errorText: _error),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: widget.multiline ? null : (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}
