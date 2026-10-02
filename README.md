# Doc Reader

A free-first, offline mobile app to read, edit and convert PDF, Word, Excel and PowerPoint files, with a dark-first glass ("glassmorphism") design. Built with Flutter for iPhone and Android.

Design mockups: https://claude.ai/artifact/LdQHpG5vTupRWF8ajzsBk6

## What works today

- **Library**: import files from the system picker (Files, iCloud Drive, Google Drive and other providers), recent files, favorites, filters, search, share, delete. Files are copied into the app so they stay available offline.
- **PDF reader** (PDFium via `pdfrx`): smooth scrolling, pinch-to-zoom, text selection, search with match highlighting, table of contents, password-protected PDFs, Paper / Sepia / Night page tones, tap to hide the floating glass bars.
- **Word (.docx) reader**: headings, title, bold / italic / underline / colors / highlights, lists, alignment, tables and images, with an outline to jump between headings.
- **Excel (.xlsx) reader**: sheet tabs, grid with row and column headers, formula bar showing a cell's value or formula.
- **PowerPoint (.pptx) reader**: slides drawn to scale with text boxes, placeholders (positions inherited from layouts and masters) and pictures, plus a full-screen swipe presenter.
- **Convert screen**: pick a file and a target (PDF to Word/Excel/PowerPoint, and each Office format to PDF). The conversion engine itself is the next milestone.
- **Settings**: dark / light / system theme, page tone, Office compatibility notes.

## Office compatibility

Office files are read (and will be written) as standard Office Open XML (.docx, .xlsx, .pptx) so they open correctly in Microsoft 365 on Windows, Mac and the web. New documents will default to standard fonts (Calibri, Arial, Times New Roman). Advanced features such as macros, heavy SmartArt, embedded OLE objects and pixel-exact floating elements may look slightly different, as in any mobile editor. Legacy binary files (.doc, .xls, .ppt) are listed but not previewed yet.

## Roadmap

1. Conversion engine (Office to PDF, PDF to Office)
2. PDF annotation: highlight, underline, draw, signature
3. Editing for Word, Excel and PowerPoint with auto-save and version history
4. Scan with OCR, batch convert, password-lock documents
5. Open-in from WhatsApp and Mail (share extension), smart folders

## Development

```sh
flutter pub get
flutter analyze
flutter test
flutter run            # on a connected iPhone or Android device / simulator
```

`tool/make_fixtures.py` regenerates the small Office files in `test/fixtures/` that the reader tests use.

Project layout:

- `lib/services/ooxml/` - dependency-free readers for .docx, .xlsx and .pptx
- `lib/services/` - library (recents, favorites) and settings stores, file actions
- `lib/screens/` - Home, Files, Convert, Settings, PDF reader, Office reader
- `lib/widgets/` - glass panels, glowing file badges, reader bars
- `lib/theme/` - colors and type (Sora for display, Manrope for UI)
