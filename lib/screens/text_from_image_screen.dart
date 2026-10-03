import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../app_scope.dart';
import '../services/error_text.dart';
import '../services/library_store.dart';
import '../services/ocr.dart';
import '../services/ooxml/docx_reader.dart';
import '../services/ooxml/docx_writer.dart';
import '../services/scanner.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import 'office_reader_screen.dart';

/// Reads the text in photos or scans, on the phone, to copy, share or save
/// as a Word document.
class TextFromImageScreen extends StatefulWidget {
  const TextFromImageScreen({super.key, this.scan = false});

  /// Start with the camera scanner instead of the gallery.
  final bool scan;

  @override
  State<TextFromImageScreen> createState() => _TextFromImageScreenState();
}

class _TextFromImageScreenState extends State<TextFromImageScreen> {
  final _text = TextEditingController();
  final _reader = TextReader();
  bool _busy = false;
  bool _picking = false;
  bool _saving = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.scan ? _fromScan() : _fromGallery());
  }

  @override
  void dispose() {
    _text.dispose();
    _reader.close();
    super.dispose();
  }

  Future<void> _fromGallery() async {
    if (_picking || _busy) return;
    final messenger = ScaffoldMessenger.of(context);
    List<Uint8List> pictures;
    setState(() => _picking = true);
    try {
      final picked = await FilePicker.pickFiles(type: FileType.image);
      pictures = [for (final f in picked) await f.readAsBytes()];
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Could not open the pictures. ${errorText(e)}')));
      return;
    } finally {
      if (mounted) setState(() => _picking = false);
    }
    if (pictures.isNotEmpty) await _read(pictures);
  }

  Future<void> _fromScan() async {
    if (_picking || _busy) return;
    final messenger = ScaffoldMessenger.of(context);
    List<Uint8List>? pages;
    setState(() => _picking = true);
    try {
      pages = await scanPages();
    } on ScanUnavailable catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('The scan did not work. ${errorText(e)}')));
      return;
    } finally {
      if (mounted) setState(() => _picking = false);
    }
    if (pages != null && pages.isNotEmpty) await _read(pages);
  }

  Future<void> _read(List<Uint8List> pictures) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final parts = <String>[];
      for (var i = 0; i < pictures.length; i++) {
        if (!mounted) return;
        setState(() => _status = pictures.length == 1 ? 'Reading the text…' : 'Reading picture ${i + 1} of ${pictures.length}…');
        final text = await _reader.readPictureText(pictures[i]);
        if (text.trim().isNotEmpty) parts.add(text.trim());
      }
      if (!mounted) return;
      if (parts.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('No text found. Try a sharper, well-lit picture.')));
        return;
      }
      final before = _text.text.trim();
      _text.text = [if (before.isNotEmpty) before, ...parts].join('\n\n');
    } on OcrUnavailable catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      // Leaving the screen closes the reader, which stops the read.
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('The text could not be read. ${errorText(e)}')));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _text.text));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied.')));
  }

  Future<void> _share() => SharePlus.instance.share(ShareParams(text: _text.text));

  Future<void> _saveAsWord() async {
    if (_saving) return;
    final library = AppScope.of(context).library;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final firstLine = _text.text.trim().split('\n').first;
    final name = safeBaseName(firstLine.length > 40 ? firstLine.substring(0, 40) : firstLine, fallback: 'Scanned text');
    setState(() => _saving = true);
    try {
      final paragraphs = _text.text.trim().split(RegExp(r'\n\s*\n'));
      final bytes = DocxWriter.write(
        DocxDocument([for (final para in paragraphs) DocxParagraph(runs: [DocxRun(para.trim())])]),
        title: name,
      );
      final file = await library.importBytes('$name.docx', bytes);
      if (!mounted) return;
      await navigator.push(MaterialPageRoute<void>(builder: (_) => OfficeReaderScreen(file: file, startEditing: true)));
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Could not save. ${errorText(e)}')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: _text,
      builder: (context, _) {
        final hasText = _text.text.trim().isNotEmpty;
        return Scaffold(
          backgroundColor: p.background,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: const Text('Text from pictures'),
            actions: [
              IconButton(tooltip: 'Scan with the camera', onPressed: _busy || _picking ? null : _fromScan, icon: const Icon(Icons.document_scanner_outlined)),
              IconButton(tooltip: 'Pick pictures', onPressed: _busy || _picking ? null : _fromGallery, icon: const Icon(Icons.add_photo_alternate_outlined)),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_busy) ...[
                  const LinearProgressIndicator(),
                  Padding(padding: const EdgeInsets.all(12), child: Text(_status ?? '', textAlign: TextAlign.center, style: TextStyle(color: p.textMuted))),
                ],
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: GlassPanel(
                      radius: 20,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      child: TextField(
                        key: const Key('ocr-text'),
                        controller: _text,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Pick a photo or scan a page. The text appears here, ready to edit.\n\nWorks on the phone, with no upload, for English and other languages written in the Latin alphabet.',
                          hintStyle: TextStyle(color: p.textMuted, height: 1.4),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                  child: Row(
                    children: [
                      Expanded(child: OutlinedButton.icon(onPressed: hasText ? _copy : null, icon: const Icon(Icons.copy_rounded), label: const Text('Copy'))),
                      const SizedBox(width: 8),
                      Expanded(child: OutlinedButton.icon(onPressed: hasText ? _share : null, icon: const Icon(Icons.ios_share_rounded), label: const Text('Share'))),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          key: const Key('ocr-word'),
                          onPressed: hasText && !_saving ? _saveAsWord : null,
                          icon: const Icon(Icons.description_outlined),
                          label: const Text('Word'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
