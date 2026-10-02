import 'package:path/path.dart' as p;

/// The document families the app understands.
enum DocKind {
  pdf('PDF'),
  word('Word'),
  excel('Excel'),
  powerpoint('PowerPoint'),
  other('File');

  const DocKind(this.label);

  final String label;

  static DocKind fromPath(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.pdf':
        return DocKind.pdf;
      case '.doc':
      case '.docx':
        return DocKind.word;
      case '.xls':
      case '.xlsx':
        return DocKind.excel;
      case '.ppt':
      case '.pptx':
        return DocKind.powerpoint;
      default:
        return DocKind.other;
    }
  }
}

/// A file in the user's library (recents + favorites).
class DocFile {
  const DocFile({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.openedAt,
    this.favorite = false,
  });

  final String path;
  final String name;
  final int sizeBytes;
  final DateTime openedAt;
  final bool favorite;

  DocKind get kind => DocKind.fromPath(name);

  String get extension => p.extension(name).replaceFirst('.', '').toLowerCase();

  /// True for the legacy binary formats (.doc/.xls/.ppt) that are not OOXML.
  bool get isLegacyBinary => const {'doc', 'xls', 'ppt'}.contains(extension);

  String get displayName => p.basenameWithoutExtension(name);

  DocFile copyWith({DateTime? openedAt, bool? favorite}) => DocFile(
        path: path,
        name: name,
        sizeBytes: sizeBytes,
        openedAt: openedAt ?? this.openedAt,
        favorite: favorite ?? this.favorite,
      );

  Map<String, Object?> toJson() => {
        'path': path,
        'name': name,
        'size': sizeBytes,
        'openedAt': openedAt.toIso8601String(),
        'favorite': favorite,
      };

  static DocFile fromJson(Map<String, Object?> json) => DocFile(
        path: json['path'] as String,
        name: json['name'] as String,
        sizeBytes: (json['size'] as num?)?.toInt() ?? 0,
        openedAt: DateTime.tryParse(json['openedAt'] as String? ?? '') ?? DateTime.now(),
        favorite: json['favorite'] as bool? ?? false,
      );
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  return mb < 10 ? '${mb.toStringAsFixed(1)} MB' : '${mb.round()} MB';
}

String formatRelative(DateTime time, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final diff = current.difference(time);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  if (diff.inDays == 1) return 'Yesterday';
  if (diff.inDays < 7) return const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][time.weekday - 1];
  return '${time.day}/${time.month}/${time.year}';
}
