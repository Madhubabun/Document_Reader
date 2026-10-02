import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/ooxml/pptx_reader.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass.dart';
import 'word_view.dart';

/// Scrollable list of slides; tap one to present full screen.
class SlidesView extends StatefulWidget {
  const SlidesView({super.key, required this.presentation, required this.outlineRequests, required this.onStatus});

  final PptxPresentation presentation;
  final ValueListenable<int> outlineRequests;
  final ValueChanged<String> onStatus;

  @override
  State<SlidesView> createState() => _SlidesViewState();
}

class _SlidesViewState extends State<SlidesView> {
  final _scroll = ScrollController();
  late final List<GlobalKey> _keys = List.generate(widget.presentation.slides.length, (_) => GlobalKey());

  @override
  void initState() {
    super.initState();
    widget.outlineRequests.addListener(_showSlides);
  }

  @override
  void dispose() {
    widget.outlineRequests.removeListener(_showSlides);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _showSlides() async {
    final slides = widget.presentation.slides;
    final index = await showGlassSheet<int>(context, (sheet) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Slides', style: Theme.of(sheet).textTheme.titleLarge),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.55),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (var i = 0; i < slides.length; i++)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Text('${i + 1}', style: TextStyle(fontWeight: FontWeight.w800, color: FileColors.powerpoint.withValues(alpha: 0.95))),
                    title: Text(slides[i].title ?? 'Slide ${i + 1}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(sheet, i),
                  ),
              ],
            ),
          ),
        ],
      );
    });
    final ctx = index == null ? null : _keys[index].currentContext;
    if (ctx != null && ctx.mounted) await Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.2);
  }

  @override
  Widget build(BuildContext context) {
    final pres = widget.presentation;
    widget.onStatus('${pres.slides.length} ${pres.slides.length == 1 ? 'slide' : 'slides'}');
    final p = context.palette;
    return ListView.separated(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 92, 16, 140),
      itemCount: pres.slides.length,
      separatorBuilder: (_, _) => const SizedBox(height: 18),
      itemBuilder: (context, i) => Column(
        key: _keys[i],
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              fullscreenDialog: true,
              builder: (_) => PresentationScreen(presentation: pres, initialSlide: i),
            )),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                boxShadow: [BoxShadow(color: FileColors.powerpoint.withValues(alpha: 0.18 * p.glowOpacity), blurRadius: 30)],
              ),
              child: ClipRRect(borderRadius: BorderRadius.circular(8), child: SlideCanvas(presentation: pres, slide: pres.slides[i])),
            ),
          ),
          const SizedBox(height: 6),
          Text('${i + 1}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.textMuted)),
        ],
      ),
    );
  }
}

/// Draws one slide at any size by scaling EMU coordinates.
class SlideCanvas extends StatelessWidget {
  const SlideCanvas({super.key, required this.presentation, required this.slide});

  final PptxPresentation presentation;
  final PptxSlide slide;

  static const _emuPerPt = 12700;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: presentation.aspectRatio,
      child: LayoutBuilder(builder: (context, box) {
        final scale = box.maxWidth / presentation.slideWidth;
        final w = presentation.slideWidth.toDouble();
        final h = presentation.slideHeight.toDouble();
        var autoTop = 0.08;
        final children = <Widget>[];
        for (final shape in slide.shapes) {
          var rect = shape.rect;
          if (rect == null) {
            // Placeholder positions inherited from the layout: approximate them.
            final isTitle = shape.kind == PptxShapeKind.title;
            rect = EmuRect((w * 0.07).round(), (h * (isTitle ? 0.06 : autoTop)).round(), (w * 0.86).round(), (h * (isTitle ? 0.18 : 0.62)).round());
            autoTop = isTitle ? 0.28 : autoTop + 0.62;
          }
          final r = Rect.fromLTWH(rect.x * scale, rect.y * scale, rect.width * scale, rect.height * scale);
          children.add(Positioned.fromRect(rect: r, child: _shape(shape, scale, r.width)));
        }
        final bgImage = slide.backgroundImage;
        return Container(
          decoration: BoxDecoration(
            color: _hex(slide.background) ?? Colors.white,
            image: bgImage == null ? null : DecorationImage(image: MemoryImage(bgImage), fit: BoxFit.fill),
          ),
          child: Stack(clipBehavior: Clip.hardEdge, children: children),
        );
      }),
    );
  }

  Widget _shape(PptxShape shape, double scale, double width) {
    if (shape.kind == PptxShapeKind.picture && shape.imageBytes != null) {
      return Image.memory(shape.imageBytes!, fit: BoxFit.fill, errorBuilder: (_, _, _) => const SizedBox.shrink());
    }
    final defaultPt = switch (shape.kind) {
      PptxShapeKind.title => 40.0,
      PptxShapeKind.body => 24.0,
      _ => 18.0,
    };
    final paragraphs = shape.paragraphs;
    return Container(
      color: _hex(shape.fill),
      padding: EdgeInsets.all(91440 * scale), // 0.1in text inset
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: switch (shape.anchor) {
          'ctr' => Alignment.centerLeft,
          'b' => Alignment.bottomLeft,
          _ => Alignment.topLeft,
        },
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: (width - 2 * 91440 * scale).clamp(20, double.infinity)),
          child: Column(
            // Stretch so centred and right-aligned paragraphs line up across the box.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final para in paragraphs)
                Padding(
                  padding: EdgeInsets.only(left: para.level * 28 * _emuPerPt * scale),
                  child: Text.rich(
                    TextSpan(children: [
                      if (para.bullet && para.text.trim().isNotEmpty) const TextSpan(text: '•  '),
                      for (final run in para.runs)
                        TextSpan(
                          text: run.text,
                          style: TextStyle(
                            fontSize: (run.fontSizePt ?? defaultPt) * _emuPerPt * scale,
                            fontWeight: run.bold || shape.kind == PptxShapeKind.title ? FontWeight.w700 : FontWeight.w400,
                            fontStyle: run.italic ? FontStyle.italic : null,
                            color: _hex(run.color),
                          ),
                        ),
                    ]),
                    textAlign: switch (para.align) {
                      'ctr' => TextAlign.center,
                      'r' => TextAlign.right,
                      'just' => TextAlign.justify,
                      _ => TextAlign.left,
                    },
                    style: TextStyle(
                      fontFamily: 'Calibri',
                      fontFamilyFallback: officeFontFallback,
                      fontSize: defaultPt * _emuPerPt * scale,
                      height: 1.15,
                      color: const Color(0xFF1F2937),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static Color? _hex(String? hex) {
    if (hex == null || hex.length != 6) return null;
    final v = int.tryParse(hex, radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }
}

/// Full-screen presenter: swipe between slides, tap to close.
class PresentationScreen extends StatefulWidget {
  const PresentationScreen({super.key, required this.presentation, required this.initialSlide});

  final PptxPresentation presentation;
  final int initialSlide;

  @override
  State<PresentationScreen> createState() => _PresentationScreenState();
}

class _PresentationScreenState extends State<PresentationScreen> {
  late final _pages = PageController(initialPage: widget.initialSlide);
  late int _index = widget.initialSlide;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slides = widget.presentation.slides;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: slides.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => Center(child: SlideCanvas(presentation: widget.presentation, slide: slides[i])),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: GlassIconButton(icon: Icons.close_rounded, tooltip: 'Exit presentation', onPressed: () => Navigator.pop(context), color: Colors.white),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('${_index + 1} / ${slides.length}', style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
