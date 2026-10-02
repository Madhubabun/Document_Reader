import 'dart:typed_data';

import 'ooxml_writer.dart';
import 'pptx_reader.dart';

/// Writes a [PptxPresentation] as a standard .pptx that opens in PowerPoint.
///
/// Supports pictures and text boxes; every slide uses one blank layout on a
/// Calibri-based Office theme.
class PptxWriter {
  static const _a = 'http://schemas.openxmlformats.org/drawingml/2006/main';
  static const _r = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  static const _p = 'http://schemas.openxmlformats.org/presentationml/2006/main';
  static const _ns = 'xmlns:a="$_a" xmlns:r="$_r" xmlns:p="$_p"';
  static const _ct = 'application/vnd.openxmlformats-officedocument.presentationml';

  static Uint8List write(PptxPresentation pres, {String title = ''}) {
    final pkg = OoxmlPackageWriter();
    final presRels = <(String, String, String)>[
      ('rId1', OoxmlPackageWriter.relType('slideMaster'), 'slideMasters/slideMaster1.xml'),
      ('rId2', OoxmlPackageWriter.relType('theme'), 'theme/theme1.xml'),
    ];
    final ids = StringBuffer();
    var media = 0;
    for (var i = 0; i < pres.slides.length; i++) {
      final n = i + 1;
      final slideRels = <(String, String, String)>[
        ('rId1', OoxmlPackageWriter.relType('slideLayout'), '../slideLayouts/slideLayout1.xml'),
      ];
      final shapes = StringBuffer();
      var shapeId = 2;
      for (final shape in pres.slides[i].shapes) {
        final rect = shape.rect ?? EmuRect(0, 0, pres.slideWidth, pres.slideHeight);
        if (shape.kind == PptxShapeKind.picture && shape.imageBytes != null) {
          media++;
          final ext = OoxmlPackageWriter.imageExtension(shape.imageBytes!);
          pkg.addBinary('ppt/media/image$media.$ext', shape.imageBytes!);
          final rid = 'rId${slideRels.length + 1}';
          slideRels.add((rid, OoxmlPackageWriter.relType('image'), '../media/image$media.$ext'));
          shapes.write(_picture(shapeId, rid, rect));
        } else if (shape.paragraphs.isNotEmpty) {
          shapes.write(_textBox(shapeId, shape, rect));
        }
        shapeId++;
      }
      final bg = pres.slides[i].background;
      final bgImage = pres.slides[i].backgroundImage;
      var bgXml = bg == null ? '' : '<p:bg><p:bgPr><a:solidFill><a:srgbClr val="$bg"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>';
      if (bgImage != null) {
        media++;
        final ext = OoxmlPackageWriter.imageExtension(bgImage);
        pkg.addBinary('ppt/media/image$media.$ext', bgImage);
        final rid = 'rId${slideRels.length + 1}';
        slideRels.add((rid, OoxmlPackageWriter.relType('image'), '../media/image$media.$ext'));
        bgXml = '<p:bg><p:bgPr><a:blipFill dpi="0" rotWithShape="1"><a:blip r:embed="$rid"/><a:srcRect/><a:stretch><a:fillRect/></a:stretch></a:blipFill>'
            '<a:effectLst/></p:bgPr></p:bg>';
      }
      pkg.addXml(
        'ppt/slides/slide$n.xml',
        '<p:sld $_ns><p:cSld>'
            '$bgXml'
            '<p:spTree>$_groupProps$shapes</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>',
        contentType: '$_ct.slide+xml',
      );
      pkg.addXml('ppt/slides/_rels/slide$n.xml.rels', OoxmlPackageWriter.rels(slideRels));
      presRels.add(('rId${n + 2}', OoxmlPackageWriter.relType('slide'), 'slides/slide$n.xml'));
      ids.write('<p:sldId id="${255 + n}" r:id="rId${n + 2}"/>');
    }

    pkg.addXml(
      'ppt/presentation.xml',
      '<p:presentation $_ns saveSubsetFonts="1"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
          '${pres.slides.isEmpty ? '' : '<p:sldIdLst>$ids</p:sldIdLst>'}'
          '<p:sldSz cx="${pres.slideWidth}" cy="${pres.slideHeight}"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>',
      contentType: '$_ct.presentation.main+xml',
    );
    pkg.addXml('ppt/_rels/presentation.xml.rels', OoxmlPackageWriter.rels(presRels));
    pkg.addXml(
      'ppt/slideMasters/slideMaster1.xml',
      '<p:sldMaster $_ns><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>$_groupProps</p:spTree></p:cSld>'
          '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" '
          'accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>'
          '<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>'
          '<p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz="4400"><a:latin typeface="+mj-lt"/></a:defRPr></a:lvl1pPr></p:titleStyle>'
          '<p:bodyStyle><a:lvl1pPr><a:defRPr sz="2800"><a:latin typeface="+mn-lt"/></a:defRPr></a:lvl1pPr></p:bodyStyle>'
          '<p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"><a:latin typeface="+mn-lt"/></a:defRPr></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>',
      contentType: '$_ct.slideMaster+xml',
    );
    pkg.addXml(
      'ppt/slideMasters/_rels/slideMaster1.xml.rels',
      OoxmlPackageWriter.rels([
        ('rId1', OoxmlPackageWriter.relType('slideLayout'), '../slideLayouts/slideLayout1.xml'),
        ('rId2', OoxmlPackageWriter.relType('theme'), '../theme/theme1.xml'),
      ]),
    );
    pkg.addXml(
      'ppt/slideLayouts/slideLayout1.xml',
      '<p:sldLayout $_ns type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>$_groupProps</p:spTree></p:cSld>'
          '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>',
      contentType: '$_ct.slideLayout+xml',
    );
    pkg.addXml(
      'ppt/slideLayouts/_rels/slideLayout1.xml.rels',
      OoxmlPackageWriter.rels([('rId1', OoxmlPackageWriter.relType('slideMaster'), '../slideMasters/slideMaster1.xml')]),
    );
    pkg.addXml('ppt/theme/theme1.xml', _theme, contentType: 'application/vnd.openxmlformats-officedocument.theme+xml');
    pkg.addRootRels('ppt/presentation.xml');
    pkg.addDocProps(title: title);
    return pkg.build();
  }

  static const _groupProps = '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
      '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>';

  static String _xfrm(EmuRect r) => '<a:xfrm><a:off x="${r.x}" y="${r.y}"/><a:ext cx="${r.width}" cy="${r.height}"/></a:xfrm>';

  static String _picture(int id, String rid, EmuRect r) =>
      '<p:pic><p:nvPicPr><p:cNvPr id="$id" name="Picture ${id - 1}"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>'
      '<p:blipFill><a:blip r:embed="$rid"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
      '<p:spPr>${_xfrm(r)}<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>';

  static String _textBox(int id, PptxShape shape, EmuRect r) {
    final b = StringBuffer('<p:sp><p:nvSpPr><p:cNvPr id="$id" name="TextBox ${id - 1}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>'
        '<p:spPr>${_xfrm(r)}<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>'
        '${shape.fill == null ? '<a:noFill/>' : '<a:solidFill><a:srgbClr val="${shape.fill}"/></a:solidFill>'}</p:spPr>'
        '<p:txBody><a:bodyPr wrap="square" rtlCol="0" anchor="${shape.anchor}"><a:spAutoFit/></a:bodyPr><a:lstStyle/>');
    for (final p in shape.paragraphs) {
      b.write('<a:p>');
      final algn = p.align == 'l' ? '' : ' algn="${p.align}"';
      if (p.level > 0 || algn.isNotEmpty || p.bullet) {
        b.write('<a:pPr${p.level > 0 ? ' lvl="${p.level}"' : ''}$algn${p.bullet ? ' marL="${285750 * (p.level + 1)}" indent="-285750"' : ''}>');
        b.write(p.bullet ? '<a:buFont typeface="Arial"/><a:buChar char="•"/>' : '');
        b.write('</a:pPr>');
      }
      for (final run in p.runs) {
        if (run.text == '\n') {
          b.write('<a:br><a:rPr lang="en-US"/></a:br>');
          continue;
        }
        b.write('<a:r><a:rPr lang="en-US"${run.fontSizePt == null ? '' : ' sz="${(run.fontSizePt! * 100).round()}"'}'
            '${run.bold ? ' b="1"' : ''}${run.italic ? ' i="1"' : ''} dirty="0">'
            '${run.color == null ? '' : '<a:solidFill><a:srgbClr val="${run.color}"/></a:solidFill>'}'
            '<a:latin typeface="Calibri"/></a:rPr><a:t>${OoxmlPackageWriter.esc(run.text)}</a:t></a:r>');
      }
      b.write('<a:endParaRPr lang="en-US" dirty="0"/></a:p>');
    }
    b.write('</p:txBody></p:sp>');
    return b.toString();
  }

  /// The Calibri-based Office theme new presentations use.
  static String get officeTheme => _theme;

  static final _theme = () {
    String c(String name, String hex) => '<a:$name><a:srgbClr val="$hex"/></a:$name>';
    const solid = '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>';
    const line = '<a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>';
    const effect = '<a:effectStyle><a:effectLst/></a:effectStyle>';
    return '<a:theme xmlns:a="$_a" name="Office Theme"><a:themeElements><a:clrScheme name="Office">'
        '<a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>'
        '${c('dk2', '44546A')}${c('lt2', 'E7E6E6')}${c('accent1', '4472C4')}${c('accent2', 'ED7D31')}${c('accent3', 'A5A5A5')}'
        '${c('accent4', 'FFC000')}${c('accent5', '5B9BD5')}${c('accent6', '70AD47')}${c('hlink', '0563C1')}${c('folHlink', '954F72')}'
        '</a:clrScheme><a:fontScheme name="Office">'
        '<a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>'
        '<a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>'
        '<a:fmtScheme name="Office"><a:fillStyleLst>$solid$solid$solid</a:fillStyleLst><a:lnStyleLst>$line$line$line</a:lnStyleLst>'
        '<a:effectStyleLst>$effect$effect$effect</a:effectStyleLst><a:bgFillStyleLst>$solid$solid$solid</a:bgFillStyleLst></a:fmtScheme>'
        '</a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>';
  }();
}
