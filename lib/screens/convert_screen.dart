import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../app_scope.dart';
import '../models/conversion.dart';
import '../models/doc_file.dart';
import '../services/convert/converter.dart';
import '../services/document_actions.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';

class ConvertScreen extends StatefulWidget {
  const ConvertScreen({super.key});

  @override
  State<ConvertScreen> createState() => _ConvertScreenState();
}

class _ConvertScreenState extends State<ConvertScreen> {
  DocFile? _source;
  ConversionTarget? _target;
  bool _keepLayout = true;
  bool _busy = false;

  void _setSource(DocFile file) {
    final targets = conversionTargets(file.kind);
    setState(() {
      _source = file;
      _target = targets.isEmpty ? null : targets.first;
    });
  }

  Future<void> _chooseSource() async {
    final library = AppScope.of(context).library;
    final candidates = library.files.where((f) => conversionTargets(f.kind).isNotEmpty && !f.isLegacyBinary).toList();
    final picked = await showGlassSheet<DocFile>(context, (sheet) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Pick a file', style: Theme.of(sheet).textTheme.titleLarge),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.5),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final f in candidates)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: FileTypeBadge(kind: f.kind, size: 34),
                    title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(formatBytes(f.sizeBytes)),
                    onTap: () => Navigator.pop(sheet, f),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              Navigator.pop(sheet);
              final imported = await importDocuments(context, openFirst: false);
              if (imported.isNotEmpty && mounted) _setSource(imported.first);
            },
            icon: const Icon(Icons.file_download_outlined),
            label: const Text('Import from Files, iCloud or Drive'),
          ),
        ],
      );
    });
    if (picked != null) _setSource(picked);
  }

  String _layoutHint(DocKind kind) => kind == DocKind.pdf
      ? 'Start a new Word page for each PDF page'
      : 'Uses your page size, fonts and spacing';

  Future<void> _convert() async {
    final source = _source!;
    final target = _target!;
    final library = AppScope.of(context).library;
    setState(() => _busy = true);
    try {
      final bytes = await convertFile(
        source.path,
        target.extension,
        fonts: loadBundledOfficeFonts,
        keepLayout: _keepLayout,
        passwordProvider: _askPassword,
      );
      final saved = await library.importBytes(convertedName(source.name, target.extension), bytes);
      if (!mounted) return;
      await _showResult(saved, target);
    } on PdfPasswordException {
      if (mounted) _showError('Wrong password', 'That password did not unlock the PDF. Try again.');
    } on NoTextException {
      if (mounted) {
        _showError('No text found', 'This PDF looks like scanned images, so there is no text to edit. Convert it to PowerPoint to keep the pages as pictures.');
      }
    } catch (e) {
      if (mounted) _showError('Could not convert', 'Something in this file is not supported yet.\n\n$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askPassword() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Password protected'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'PDF password'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Unlock')),
        ],
      ),
    );
  }

  Future<void> _showResult(DocFile saved, ConversionTarget target) {
    final p = context.palette;
    final note = target.kind == DocKind.powerpoint
        ? 'Each page is a full-quality picture on its own slide, so it looks exactly like the PDF.'
        : target.kind == DocKind.pdf
            ? 'Saved with Calibri-compatible fonts and your original page size.'
            : 'Saved as a standard .${target.extension} file that opens in Microsoft 365. '
                'Complex layouts, macros, SmartArt and embedded objects may look slightly different.';
    return showGlassSheet<void>(
      context,
      (sheet) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              FileTypeBadge(kind: saved.kind, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Converted', style: Theme.of(sheet).textTheme.titleLarge),
                    Text(saved.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.textMuted)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(note, style: TextStyle(color: p.textMuted, height: 1.4, fontSize: 13)),
          const SizedBox(height: 18),
          NeonButton(
            label: 'Open',
            icon: Icons.open_in_new_rounded,
            onPressed: () {
              Navigator.pop(sheet);
              openDocument(context, saved);
            },
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => shareDocument(saved),
            icon: const Icon(Icons.ios_share_rounded),
            label: const Text('Share'),
          ),
        ],
      ),
    );
  }

  void _showError(String title, String detail) => showComingSoon(context, title, detail);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final source = _source;
    final targets = source == null ? const <ConversionTarget>[] : conversionTargets(source.kind);
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 130),
        children: [
          Text(
            'Convert',
            style: TextStyle(
              fontFamily: AppTheme.displayFont,
              fontSize: 32,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
              color: p.text,
              shadows: p.isDark ? [const Shadow(color: Color(0x8CA78BFA), blurRadius: 24)] : null,
            ),
          ),
          const SizedBox(height: 4),
          Text('Any format, right on your phone.', style: TextStyle(color: p.textMuted, fontSize: 14, fontWeight: FontWeight.w500)),
          const SizedBox(height: 18),
          if (source == null)
            GlassPanel(
              radius: 24,
              child: InkWell(
                onTap: _chooseSource,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
                  child: Column(
                    children: [
                      Icon(Icons.upload_file_rounded, size: 34, color: p.accent),
                      const SizedBox(height: 10),
                      const Text('Choose a file to convert', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text('PDF, Word, Excel or PowerPoint', style: TextStyle(color: p.textMuted, fontSize: 13)),
                    ],
                  ),
                ),
              ),
            )
          else
            GlassPanel(
              tint: FileColors.of(source.kind),
              glow: FileColors.of(source.kind),
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  FileTypeBadge(kind: source.kind, size: 46),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(source.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 3),
                        Text(formatBytes(source.sizeBytes), style: TextStyle(fontSize: 12, color: p.textMuted)),
                      ],
                    ),
                  ),
                  OutlinedButton(onPressed: _chooseSource, child: const Text('Change')),
                ],
              ),
            ),
          if (source != null) ...[
            const SizedBox(height: 22),
            Text('Convert to', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 17)),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.05,
              children: [for (final t in targets) _TargetTile(target: t, selected: t == _target, onTap: () => setState(() => _target = t))],
            ),
            const SizedBox(height: 18),
            GlassPanel(
              radius: 20,
              child: Column(
                children: [
                  SwitchListTile.adaptive(
                    value: _keepLayout,
                    onChanged: (v) => setState(() => _keepLayout = v),
                    title: const Text('Keep original layout', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(_layoutHint(source.kind), style: TextStyle(fontSize: 12, color: p.textMuted)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            NeonButton(
              label: _busy ? 'Converting…' : (_target == null ? 'Convert' : 'Convert to ${_target!.label}'),
              icon: Icons.arrow_forward_rounded,
              onPressed: _target == null || _busy ? null : _convert,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline_rounded, size: 14, color: p.textMuted),
                const SizedBox(width: 6),
                Text('On-device · Private · No watermarks', style: TextStyle(fontSize: 12, color: p.textMuted, fontWeight: FontWeight.w600)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({required this.target, required this.selected, required this.onTap});

  final ConversionTarget target;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = FileColors.of(target.kind);
    return Semantics(
      selected: selected,
      button: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: selected ? [BoxShadow(color: color.withValues(alpha: 0.45 * context.palette.glowOpacity), blurRadius: 26)] : null,
        ),
        child: GlassPanel(
          radius: 20,
          tint: selected ? color : null,
          child: InkWell(
            onTap: onTap,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FileTypeBadge(kind: target.kind, size: 34),
                const SizedBox(height: 8),
                Text(target.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                Text('.${target.extension}', style: TextStyle(fontSize: 11, color: context.palette.textMuted)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
