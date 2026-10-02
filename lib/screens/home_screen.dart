import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/doc_file.dart';
import '../services/document_actions.dart';
import '../theme/app_theme.dart';
import '../widgets/doc_tiles.dart';
import '../widgets/glass.dart';
import 'create_sheet.dart';
import 'pdf_tools_screen.dart';
import 'root_shell.dart';

enum HomeFilter {
  all('All'),
  favorites('Favorites'),
  pdf('PDF'),
  word('Word'),
  excel('Excel'),
  slides('Slides');

  const HomeFilter(this.label);

  final String label;

  bool matches(DocFile f) => switch (this) {
        HomeFilter.all => true,
        HomeFilter.favorites => f.favorite,
        HomeFilter.pdf => f.kind == DocKind.pdf,
        HomeFilter.word => f.kind == DocKind.word,
        HomeFilter.excel => f.kind == DocKind.excel,
        HomeFilter.slides => f.kind == DocKind.powerpoint,
      };
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.onOpenTab});

  final ValueChanged<AppTab> onOpenTab;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  HomeFilter _filter = HomeFilter.all;

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    final p = context.palette;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final all = library.files;
        final shown = all.where(_filter.matches).toList();
        final latest = all.isEmpty ? null : all.first;
        return CustomScrollView(
          slivers: [
            SliverSafeArea(
              bottom: false,
              sliver: SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                sliver: SliverList.list(children: [
                  _Header(date: DateTime.now()),
                  const SizedBox(height: 16),
                  _SearchStub(onTap: () => widget.onOpenTab(AppTab.files)),
                  const SizedBox(height: 16),
                  _QuickActions(onConvert: () => widget.onOpenTab(AppTab.convert)),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Text('Recent', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 19)),
                      const Spacer(),
                      if (all.isNotEmpty)
                        TextButton(
                          onPressed: () => widget.onOpenTab(AppTab.files),
                          child: Text('See all', style: TextStyle(color: p.accent, fontWeight: FontWeight.w700)),
                        ),
                    ],
                  ),
                  if (all.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 36,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: HomeFilter.values.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, i) {
                          final f = HomeFilter.values[i];
                          return GlassChip(label: f.label, selected: f == _filter, onTap: () => setState(() => _filter = f));
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (latest != null && _filter == HomeFilter.all) ...[
                      _ContinueCard(file: latest),
                      const SizedBox(height: 12),
                    ],
                  ],
                ]),
              ),
            ),
            if (all.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                sliver: SliverToBoxAdapter(
                  child: EmptyShelf(
                    title: 'Your shelf is empty',
                    message: 'Drop in a PDF, a deck or a spreadsheet and it lives here, ready offline.',
                    action: NeonButton(label: 'Import a file', icon: Icons.arrow_forward_rounded, onPressed: () => importDocuments(context)),
                  ),
                ),
              )
            else if (shown.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                sliver: SliverToBoxAdapter(
                  child: EmptyShelf(
                    title: _filter == HomeFilter.favorites ? 'No favorites yet' : 'Nothing here yet',
                    message: _filter == HomeFilter.favorites
                        ? 'Long-press any file and tap the star. Your go-to docs will wait for you here.'
                        : 'No ${_filter.label} files in your recents.',
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, mainAxisExtent: 150),
                  itemCount: shown.length,
                  itemBuilder: (context, i) => DocCard(file: shown[i]),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 130)),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.date});

  final DateTime date;

  static const _days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final glowColor = p.isDark ? const Color(0xFFA5F3FC) : p.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${_days[date.weekday - 1]}, ${_months[date.month - 1]} ${date.day}',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.textMuted)),
        const SizedBox(height: 2),
        Text(
          'Your docs',
          style: TextStyle(
            fontFamily: AppTheme.displayFont,
            fontSize: 34,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.7,
            color: glowColor,
            shadows: p.isDark ? [const Shadow(color: Color(0xB322D3EE), blurRadius: 22)] : null,
          ),
        ),
      ],
    );
  }
}

class _SearchStub extends StatelessWidget {
  const _SearchStub({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GlassPanel(
      radius: 16,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              const SizedBox(width: 14),
              Icon(Icons.search_rounded, color: p.textMuted, size: 22),
              const SizedBox(width: 10),
              Text('Search your files', style: TextStyle(color: p.textMuted, fontSize: 15, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.onConvert});

  final VoidCallback onConvert;

  @override
  Widget build(BuildContext context) {
    Widget tile(String label, IconData icon, Color color, VoidCallback onTap) => Expanded(
          child: GlassPanel(
            radius: 22,
            child: InkWell(
              onTap: onTap,
              child: SizedBox(
                height: 88,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(color: color.withValues(alpha: 0.45)),
                        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35 * context.palette.glowOpacity), blurRadius: 18)],
                      ),
                      child: Icon(icon, color: context.palette.isDark ? Color.lerp(color, Colors.white, 0.25) : color, size: 20),
                    ),
                    const SizedBox(height: 8),
                    Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          ),
        );
    return Row(
      children: [
        tile('Scan', Icons.document_scanner_outlined, const Color(0xFF67E8F9), () => startScan(context)),
        const SizedBox(width: 10),
        tile('New', Icons.note_add_outlined, const Color(0xFF2FD27A), () => showCreateSheet(context)),
        const SizedBox(width: 10),
        tile('Tools', Icons.handyman_outlined, const Color(0xFFA78BFA),
            () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PdfToolsScreen()))),
        const SizedBox(width: 10),
        tile('Convert', Icons.swap_horiz_rounded, const Color(0xFF7AA2FF), onConvert),
      ],
    );
  }
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.file});

  final DocFile file;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = FileColors.of(file.kind);
    return GlassPanel(
      tint: color,
      glow: color,
      radius: 26,
      child: InkWell(
        onTap: () => openDocument(context, file),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              FileTypeBadge(kind: file.kind, size: 48),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('CONTINUE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: Color.lerp(color, p.text, 0.35))),
                    const SizedBox(height: 4),
                    Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text('${file.kind.label} · ${formatRelative(file.openedAt)}', style: TextStyle(fontSize: 12, color: p.textMuted, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(shape: BoxShape.circle, color: p.text),
                child: Icon(Icons.play_arrow_rounded, color: p.background),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
