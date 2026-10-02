import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/doc_file.dart';
import '../services/document_actions.dart';
import '../theme/app_theme.dart';
import 'glass.dart';

/// Grid card for a recent file.
class DocCard extends StatelessWidget {
  const DocCard({super.key, required this.file});

  final DocFile file;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = FileColors.of(file.kind);
    return Semantics(
      button: true,
      label: '${file.name}, ${formatBytes(file.sizeBytes)}',
      child: GlassPanel(
        tint: color,
        glow: color,
        padding: const EdgeInsets.all(14),
        child: InkWell(
          onTap: () => openDocument(context, file),
          onLongPress: () => showDocMenu(context, file),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FileTypeBadge(kind: file.kind, size: 42),
                  const Spacer(),
                  if (file.favorite) const Icon(Icons.star_rounded, color: Color(0xFFFDE68A), size: 20),
                ],
              ),
              const Spacer(),
              Text(file.displayName, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.25)),
              const SizedBox(height: 4),
              Text(
                '${formatBytes(file.sizeBytes)} · ${formatRelative(file.openedAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: p.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-width row used in the Files tab.
class DocRow extends StatelessWidget {
  const DocRow({super.key, required this.file});

  final DocFile file;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = FileColors.of(file.kind);
    return GlassPanel(
      tint: color,
      radius: 22,
      child: InkWell(
        onTap: () => openDocument(context, file),
        onLongPress: () => showDocMenu(context, file),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          child: Row(
            children: [
              FileTypeBadge(kind: file.kind, size: 40),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text('${formatBytes(file.sizeBytes)} · ${formatRelative(file.openedAt)}', style: TextStyle(fontSize: 12, color: p.textMuted, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              if (file.favorite) const Icon(Icons.star_rounded, color: Color(0xFFFDE68A), size: 20),
              IconButton(
                tooltip: 'More for ${file.name}',
                onPressed: () => showDocMenu(context, file),
                icon: Icon(Icons.more_vert_rounded, color: p.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showDocMenu(BuildContext context, DocFile file) {
  final library = AppScope.of(context).library;
  return showGlassSheet<void>(context, (sheet) {
    Widget action(IconData icon, String label, VoidCallback onTap, {Color? color}) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, color: color ?? sheet.palette.text),
          title: Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: color)),
          onTap: () {
            Navigator.pop(sheet);
            onTap();
          },
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          FileTypeBadge(kind: file.kind, size: 38),
          const SizedBox(width: 14),
          Expanded(child: Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(sheet).textTheme.titleMedium)),
        ]),
        const SizedBox(height: 8),
        action(Icons.open_in_new_rounded, 'Open', () => openDocument(context, file)),
        action(file.favorite ? Icons.star_rounded : Icons.star_outline_rounded, file.favorite ? 'Remove from favorites' : 'Add to favorites', () => library.toggleFavorite(file)),
        action(Icons.ios_share_rounded, 'Share', () => shareDocument(file)),
        action(Icons.delete_outline_rounded, 'Delete from library', () => library.remove(file), color: const Color(0xFFFF7A7E)),
      ],
    );
  });
}

/// Friendly empty state.
class EmptyShelf extends StatelessWidget {
  const EmptyShelf({super.key, required this.title, required this.message, this.action});

  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
      child: Column(
        children: [
          SizedBox(
            height: 70,
            width: 130,
            child: Stack(
              alignment: Alignment.center,
              children: const [
                Positioned(left: 0, child: RotationTransition(turns: AlwaysStoppedAnimation(-0.04), child: FileTypeBadge(kind: DocKind.word, size: 40))),
                Positioned(right: 0, child: RotationTransition(turns: AlwaysStoppedAnimation(0.04), child: FileTypeBadge(kind: DocKind.excel, size: 40))),
                FileTypeBadge(kind: DocKind.pdf, size: 48),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center, style: TextStyle(color: p.textMuted, height: 1.45)),
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    );
  }
}
