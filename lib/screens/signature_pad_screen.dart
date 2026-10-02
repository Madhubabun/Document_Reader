import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Draw a signature with a finger. Pops with a transparent PNG trimmed to
/// the ink, or null.
class SignaturePadScreen extends StatefulWidget {
  const SignaturePadScreen({super.key});

  static const inks = [Color(0xFF111111), Color(0xFF1A3FB0), Color(0xFFB00020)];
  static const inkNames = ['Black', 'Blue', 'Red'];

  @override
  State<SignaturePadScreen> createState() => _SignaturePadScreenState();
}

class _SignaturePadScreenState extends State<SignaturePadScreen> {
  static const _width = 3.2;

  final _strokes = <List<Offset>>[];
  Color _ink = SignaturePadScreen.inks.first;
  bool _saving = false;

  bool get _empty => _strokes.isEmpty;

  Future<void> _save() async {
    setState(() => _saving = true);
    final png = await renderSignature(_strokes, _ink, _width);
    if (mounted) Navigator.pop(context, png);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Draw your signature'),
        actions: [
          TextButton(onPressed: _empty ? null : () => setState(_strokes.clear), child: const Text('Clear')),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(onPressed: _empty || _saving ? null : _save, child: const Text('Save')),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: ColoredBox(
                    color: Colors.white,
                    child: Stack(
                      children: [
                        Positioned(
                          left: 28,
                          right: 28,
                          bottom: 70,
                          child: Container(height: 1.5, color: Colors.black26),
                        ),
                        if (_empty)
                          const Positioned(
                            left: 0,
                            right: 0,
                            bottom: 40,
                            child: Text('Sign above the line', textAlign: TextAlign.center, style: TextStyle(color: Colors.black38)),
                          ),
                        Positioned.fill(
                          child: GestureDetector(
                            key: const Key('signature-pad'),
                            onPanStart: (d) => setState(() => _strokes.add([d.localPosition])),
                            onPanUpdate: (d) => setState(() => _strokes.last.add(d.localPosition)),
                            onTapUp: (d) => setState(() => _strokes.add([d.localPosition])),
                            child: CustomPaint(painter: _InkPainter(_strokes, _ink, _width)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < SignaturePadScreen.inks.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Semantics(
                        label: '${SignaturePadScreen.inkNames[i]} ink',
                        selected: _ink == SignaturePadScreen.inks[i],
                        button: true,
                        child: GestureDetector(
                          onTap: () => setState(() => _ink = SignaturePadScreen.inks[i]),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: SignaturePadScreen.inks[i],
                              shape: BoxShape.circle,
                              border: Border.all(color: _ink == SignaturePadScreen.inks[i] ? p.accent : Colors.white24, width: 3),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _paintInk(Canvas canvas, List<List<Offset>> strokes, Color ink, double width) {
  final paint = Paint()
    ..color = ink
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke
    ..isAntiAlias = true;
  for (final s in strokes) {
    if (s.length == 1) {
      canvas.drawCircle(s.first, width / 2, Paint()..color = ink);
      continue;
    }
    // Smooth through the midpoints so fast strokes don't look jagged.
    final path = Path()..moveTo(s.first.dx, s.first.dy);
    for (var i = 1; i < s.length - 1; i++) {
      final mid = (s[i] + s[i + 1]) / 2;
      path.quadraticBezierTo(s[i].dx, s[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(s.last.dx, s.last.dy);
    canvas.drawPath(path, paint);
  }
}

class _InkPainter extends CustomPainter {
  _InkPainter(this.strokes, this.ink, this.width);

  final List<List<Offset>> strokes;
  final Color ink;
  final double width;

  @override
  void paint(Canvas canvas, Size size) => _paintInk(canvas, strokes, ink, width);

  @override
  bool shouldRepaint(_InkPainter old) => true;
}

/// Renders [strokes] on a transparent background, cropped to the ink, at a
/// resolution that stays sharp when printed.
Future<Uint8List> renderSignature(List<List<Offset>> strokes, Color ink, double width) async {
  var bounds = Rect.fromPoints(strokes.first.first, strokes.first.first);
  for (final s in strokes) {
    for (final o in s) {
      bounds = bounds.expandToInclude(Rect.fromPoints(o, o));
    }
  }
  bounds = bounds.inflate(width * 2);
  // Around 3x the screen size, but no more than 1600 pixels wide.
  final scale = math.min(3.0, 1600 / bounds.width);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..scale(scale)
    ..translate(-bounds.left, -bounds.top);
  _paintInk(canvas, strokes, ink, width);
  final image = await recorder.endRecording().toImage((bounds.width * scale).ceil(), (bounds.height * scale).ceil());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}
