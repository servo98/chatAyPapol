import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'store.dart';
import 'theme.dart';

/// Markdown estilo Discord: **bold** *italic* __underline__ ~~strike~~
/// `code` ```bloques``` ||spoiler|| > quote, enlaces y @menciones.
/// Sin dependencias: tokenizador propio (~150 líneas).

final _urlRe = RegExp(r'https?://[^\s<>|]+');

class MdStyle {
  final TextStyle base;
  const MdStyle(this.base);
}

List<Widget> renderMarkdown(String content, AppStore store, {double fontSize = 14.5}) {
  final base = TextStyle(fontSize: fontSize, color: Pal.text, height: 1.35);
  final blocks = <Widget>[];
  final parts = content.split('```');
  for (var i = 0; i < parts.length; i++) {
    if (parts[i].isEmpty) continue;
    if (i.isOdd) {
      // bloque de código (la primera línea puede ser el lenguaje)
      var code = parts[i];
      final nl = code.indexOf('\n');
      if (nl > 0 && nl < 20 && !code.substring(0, nl).contains(' ')) {
        code = code.substring(nl + 1);
      }
      blocks.add(Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        width: double.infinity,
        decoration: BoxDecoration(
          color: Pal.bg0,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Pal.borderDefault),
        ),
        child: SelectableText(code.trimRight(),
            style: TextStyle(
                fontFamily: Pal.fontMono,
                fontFamilyFallback: Pal.monoFallback,
                fontSize: fontSize - 1.5,
                color: Pal.text)),
      ));
    } else {
      blocks.addAll(_renderLines(parts[i], store, base));
    }
  }
  return blocks;
}

List<Widget> _renderLines(String text, AppStore store, TextStyle base) {
  final out = <Widget>[];
  final plain = <String>[];
  void flush() {
    if (plain.isEmpty) return;
    final spans = _inline(plain.join('\n'), store, base);
    out.add(SelectableText.rich(TextSpan(children: spans, style: base)));
    plain.clear();
  }

  for (final line in text.split('\n')) {
    if (line.startsWith('> ') || line == '>') {
      flush();
      out.add(Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.only(left: 12),
        decoration: BoxDecoration(
            border: Border(left: BorderSide(color: Pal.faint, width: 3))),
        child: SelectableText.rich(TextSpan(
            children: _inline(line.length > 1 ? line.substring(2) : '', store,
                base.copyWith(color: Pal.muted)),
            style: base.copyWith(color: Pal.muted))),
      ));
    } else {
      plain.add(line);
    }
  }
  flush();
  return out;
}

class _Pat {
  final RegExp re;
  final InlineSpan Function(Match m, AppStore store, TextStyle style) build;
  _Pat(String pattern, this.build) : re = RegExp(pattern, dotAll: true);
}

final List<_Pat> _patterns = [
  _Pat(r'\*\*(.+?)\*\*', (m, s, st) => TextSpan(
      children: _inline(m[1]!, s, st.copyWith(fontWeight: FontWeight.w700)))),
  _Pat(r'__(.+?)__', (m, s, st) => TextSpan(
      children: _inline(m[1]!, s, st.copyWith(decoration: TextDecoration.underline)))),
  _Pat(r'~~(.+?)~~', (m, s, st) => TextSpan(
      children: _inline(m[1]!, s, st.copyWith(decoration: TextDecoration.lineThrough)))),
  _Pat(r'\|\|(.+?)\|\|', (m, s, st) =>
      WidgetSpan(child: _Spoiler(text: m[1]!, style: st), alignment: PlaceholderAlignment.middle)),
  _Pat(r'\*(.+?)\*', (m, s, st) =>
      TextSpan(children: _inline(m[1]!, s, st.copyWith(fontStyle: FontStyle.italic)))),
  _Pat(r'_(.+?)_', (m, s, st) =>
      TextSpan(children: _inline(m[1]!, s, st.copyWith(fontStyle: FontStyle.italic)))),
  _Pat(r'`([^`]+)`', (m, s, st) => TextSpan(
      text: ' ${m[1]} ',
      style: st.copyWith(
          fontFamily: Pal.fontMono,
          fontFamilyFallback: Pal.monoFallback,
          fontSize: (st.fontSize ?? 14) - 1,
          backgroundColor: Pal.bg0))),
  _Pat(_urlRe.pattern, (m, s, st) {
    final url = m[0]!;
    return TextSpan(
        text: url,
        style: st.copyWith(color: Pal.link),
        recognizer: TapGestureRecognizer()
          ..onTap = () => launchUrlString(url, mode: LaunchMode.externalApplication));
  }),
  _Pat(r'@(everyone|[a-zA-Z0-9_.]{2,32})', (m, s, st) {
    final name = m[1]!;
    final known = name == 'everyone' || s.users.values.any((u) => u.username == name);
    if (!known) return TextSpan(text: m[0], style: st);
    final mentionsMe = name == 'everyone' || name == s.me?.username;
    return TextSpan(
        text: '@$name',
        style: st.copyWith(
            color: mentionsMe ? Pal.yellow : Pal.accent,
            fontWeight: FontWeight.w700,
            backgroundColor: (mentionsMe ? Pal.yellow : Pal.accent).withValues(alpha: .12)));
  }),
];

List<InlineSpan> _inline(String text, AppStore store, TextStyle style) {
  final spans = <InlineSpan>[];
  var rest = text;
  while (rest.isNotEmpty) {
    Match? best;
    _Pat? bestPat;
    for (final p in _patterns) {
      final m = p.re.firstMatch(rest);
      if (m != null && (best == null || m.start < best.start)) {
        best = m;
        bestPat = p;
      }
    }
    if (best == null) {
      spans.add(TextSpan(text: rest, style: style));
      break;
    }
    if (best.start > 0) spans.add(TextSpan(text: rest.substring(0, best.start), style: style));
    spans.add(bestPat!.build(best, store, style));
    rest = rest.substring(best.end);
  }
  return spans;
}

class _Spoiler extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _Spoiler({required this.text, required this.style});
  @override
  State<_Spoiler> createState() => _SpoilerState();
}

class _SpoilerState extends State<_Spoiler> {
  bool revealed = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => revealed = true),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
            color: revealed ? Pal.bg0 : Pal.bg0.withValues(alpha: .95),
            borderRadius: BorderRadius.circular(5)),
        child: Text(widget.text,
            style: revealed
                ? widget.style
                : widget.style.copyWith(color: Colors.transparent)),
      ),
    );
  }
}
