import 'dart:math' as math;
import 'dart:ui';

/// Characters of a page as rectangles in the page's shown coordinates
/// (points, top-left origin), in reading order.
class PageChars {
  PageChars(this.rects, this.pageSize);

  final List<Rect> rects;
  final Size pageSize;

  /// The character nearest to [point] (fractions of the page), or null when
  /// nothing is within [reach] points.
  int? nearest(Offset point, {double reach = 24}) {
    final p = Offset(point.dx * pageSize.width, point.dy * pageSize.height);
    int? best;
    var bestDistance = reach;
    for (var i = 0; i < rects.length; i++) {
      final r = rects[i];
      if (r.isEmpty) continue;
      final dx = math.max(0.0, math.max(r.left - p.dx, p.dx - r.right));
      final dy = math.max(0.0, math.max(r.top - p.dy, p.dy - r.bottom));
      // Being on the right line matters more than being near the right letter.
      final d = math.sqrt(dx * dx + 4 * dy * dy);
      if (d < bestDistance || (d == bestDistance && best == null)) {
        bestDistance = d;
        best = i;
        if (d == 0) break;
      }
    }
    return best;
  }

  /// One rectangle per line for characters [a] to [b] (inclusive, either
  /// order), as fractions of the page.
  List<Rect> lines(int a, int b) {
    final from = math.min(a, b);
    final to = math.max(a, b);
    final out = <Rect>[];
    Rect? line;
    Rect? last;
    for (var i = from; i <= to && i < rects.length; i++) {
      final r = rects[i];
      if (r.isEmpty) continue;
      final sameLine = line != null &&
          last != null &&
          // Vertically overlapping the line by at least half the smaller height...
          math.min(line.bottom, r.bottom) - math.max(line.top, r.top) > 0.5 * math.min(line.height, r.height) &&
          // ...and not jumping back to the left (a new line or column).
          r.left >= last.left - last.height;
      if (sameLine) {
        line = line.expandToInclude(r);
      } else {
        if (line != null) out.add(line);
        line = r;
      }
      last = r;
    }
    if (line != null) out.add(line);
    return [
      for (final r in out) Rect.fromLTRB(r.left / pageSize.width, r.top / pageSize.height, r.right / pageSize.width, r.bottom / pageSize.height),
    ];
  }
}
