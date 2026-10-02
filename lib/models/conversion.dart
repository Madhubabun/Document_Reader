import 'doc_file.dart';

/// A target format offered on the Convert screen.
class ConversionTarget {
  const ConversionTarget(this.kind, this.extension, this.label);

  final DocKind kind;
  final String extension;
  final String label;
}

const _toPdf = ConversionTarget(DocKind.pdf, 'pdf', 'PDF');
const _toWord = ConversionTarget(DocKind.word, 'docx', 'Word');
const _toExcel = ConversionTarget(DocKind.excel, 'xlsx', 'Excel');
const _toSlides = ConversionTarget(DocKind.powerpoint, 'pptx', 'PowerPoint');

/// Conversions the app supports: PDF to and from each Office format.
/// Office output is always modern OOXML so it opens in Microsoft 365.
List<ConversionTarget> conversionTargets(DocKind source) => switch (source) {
      DocKind.pdf => const [_toWord, _toExcel, _toSlides],
      DocKind.word || DocKind.excel || DocKind.powerpoint => const [_toPdf],
      DocKind.other => const [],
    };
