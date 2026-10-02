import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../services/document_actions.dart';
import '../theme/app_theme.dart';
import '../widgets/doc_tiles.dart';
import '../widgets/glass.dart';
import 'home_screen.dart';

/// Every file in the library, searchable by name.
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  final _query = TextEditingController();
  HomeFilter _filter = HomeFilter.all;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    final p = context.palette;
    return SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: Listenable.merge([library, _query]),
        builder: (context, _) {
          final q = _query.text.trim().toLowerCase();
          final files = library.files.where((f) => _filter.matches(f) && (q.isEmpty || f.name.toLowerCase().contains(q))).toList();
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                sliver: SliverList.list(children: [
                  Text('Files', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 14),
                  GlassPanel(
                    radius: 16,
                    child: TextField(
                      controller: _query,
                      textInputAction: TextInputAction.search,
                      style: TextStyle(color: p.text, fontWeight: FontWeight.w600),
                      decoration: InputDecoration(
                        hintText: 'Search by name',
                        hintStyle: TextStyle(color: p.textMuted, fontWeight: FontWeight.w500),
                        prefixIcon: Icon(Icons.search_rounded, color: p.textMuted),
                        suffixIcon: q.isEmpty
                            ? null
                            : IconButton(tooltip: 'Clear search', onPressed: _query.clear, icon: Icon(Icons.close_rounded, color: p.textMuted)),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
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
                ]),
              ),
              if (files.isEmpty)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverToBoxAdapter(
                    child: library.files.isEmpty
                        ? EmptyShelf(
                            title: 'No files yet',
                            message: 'Import from Files, iCloud Drive or Google Drive. Everything stays on this phone.',
                            action: NeonButton(label: 'Import a file', onPressed: () => importDocuments(context)),
                          )
                        : const EmptyShelf(title: 'No matches', message: 'Try another name or filter.'),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverList.separated(
                    itemCount: files.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, i) => DocRow(file: files[i]),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 130)),
            ],
          );
        },
      ),
    );
  }
}
