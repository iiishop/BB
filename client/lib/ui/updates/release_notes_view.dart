import 'package:flutter/material.dart';

import '../../app.dart';

/// Renders the raw GitHub Release body for the update card.
///
/// The body is untrusted input: it may contain HTML, scripts, remote images or
/// links. This widget therefore never interprets HTML, never loads a remote
/// resource and never opens anything on its own. It supports the small Markdown
/// subset that release notes actually use — headings, paragraphs, emphasis,
/// inline code, fenced code, bullet/ordered lists, block quotes, rules and
/// links — and shows every other character literally.
///
/// Links are shown as visible text with their target: opening the target is an
/// explicit user action outside the update surface, so a release note can never
/// turn a check into a navigation or a download.
class ReleaseNotesView extends StatelessWidget {
  const ReleaseNotesView({
    super.key,
    required this.body,
    this.emptyPlaceholder = '此版本未提供更新说明',
    this.onOpenLink,
  });

  /// Raw `release.body` exactly as GitHub returned it.
  final String body;

  /// Shown when the release body is empty or whitespace only. The client must
  /// not invent notes for a release that has none.
  final String emptyPlaceholder;

  /// Supplied by the host: called with an `https` target only after the user
  /// explicitly taps the link. When null the link is inert text (no gesture).
  final void Function(String url)? onOpenLink;

  static const String emptyKey = 'update-release-notes-empty';

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final String trimmed = body.trim();
    if (trimmed.isEmpty) {
      return Text(
        emptyPlaceholder,
        key: const ValueKey<String>(emptyKey),
        style: text.bodySmall?.copyWith(
          color: AppColors.inkMuted,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    final List<Widget> blocks = _parseBlocks(context, trimmed);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: blocks,
    );
  }

  List<Widget> _parseBlocks(BuildContext context, String source) {
    final TextTheme text = Theme.of(context).textTheme;
    final List<Widget> blocks = <Widget>[];
    final List<String> lines = source.split(RegExp(r'\r?\n'));
    final StringBuffer paragraph = StringBuffer();
    int index = 0;

    void flushParagraph() {
      if (paragraph.isEmpty) {
        return;
      }
      blocks.add(
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: Text.rich(
            TextSpan(children: _parseInline(paragraph.toString(), text)),
          ),
        ),
      );
      paragraph.clear();
    }

    while (index < lines.length) {
      final String line = lines[index];
      final String trimmed = line.trimRight();

      if (trimmed.trim().isEmpty) {
        flushParagraph();
        index += 1;
        continue;
      }

      final RegExpMatch? fence = RegExp(r'^\s*```').firstMatch(trimmed);
      if (fence != null) {
        flushParagraph();
        // A fence language is display metadata only; nothing loads it.
        final StringBuffer code = StringBuffer();
        index += 1;
        while (index < lines.length &&
            !RegExp(r'^\s*```').hasMatch(lines[index])) {
          if (code.isNotEmpty) {
            code.write('\n');
          }
          code.write(lines[index]);
          index += 1;
        }
        // Skip the closing fence; an unterminated fence still shows the text
        // instead of swallowing the rest of the notes.
        if (index < lines.length) {
          index += 1;
        }
        blocks.add(
          Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: AppColors.paper,
              borderRadius: BorderRadius.circular(AppRadius.brand),
              border: Border.all(color: AppColors.border),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                code.isEmpty ? ' ' : code.toString(),
                style: text.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  // Devices ship a monospace face; widget-test renders fall
                  // back to the body family instead of drawing tofu.
                  fontFamilyFallback: const <String>['Roboto'],
                  color: AppColors.ink,
                  height: 1.45,
                ),
                textAlign: TextAlign.left,
              ),
            ),
          ),
        );
        continue;
      }

      final RegExpMatch? heading = RegExp(r'^(#{1,6})\s+(.*)$')
          .firstMatch(trimmed.trim());
      if (heading != null) {
        flushParagraph();
        final int level = heading.group(1)!.length;
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(
              top: AppSpacing.xs,
              bottom: AppSpacing.xs,
            ),
            child: Text(
              _plainText(heading.group(2)!),
              style: (level <= 2 ? text.titleMedium : text.labelLarge)
                  ?.copyWith(fontWeight: FontWeight.w700, color: AppColors.ink),
            ),
          ),
        );
        index += 1;
        continue;
      }

      if (RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$').hasMatch(trimmed)) {
        flushParagraph();
        blocks.add(
          const Divider(height: AppSpacing.md, color: AppColors.border),
        );
        index += 1;
        continue;
      }

      final RegExpMatch? bullet = RegExp(r'^\s{0,3}[-*+]\s+(.*)$')
          .firstMatch(trimmed);
      if (bullet != null) {
        flushParagraph();
        blocks.add(
          _ListItem(
            marker: '•',
            spans: _parseInline(bullet.group(1)!, text),
            style: text.bodyMedium?.copyWith(
              fontSize: 14,
              height: 1.6,
              color: AppColors.ink,
            ),
          ),
        );
        index += 1;
        continue;
      }

      final RegExpMatch? ordered = RegExp(r'^\s{0,3}(\d{1,3})[.)]\s+(.*)$')
          .firstMatch(trimmed);
      if (ordered != null) {
        flushParagraph();
        blocks.add(
          _ListItem(
            marker: '${ordered.group(1)}.',
            spans: _parseInline(ordered.group(2)!, text),
            style: text.bodyMedium?.copyWith(
              fontSize: 14,
              height: 1.6,
              color: AppColors.ink,
            ),
          ),
        );
        index += 1;
        continue;
      }

      final RegExpMatch? quote = RegExp(r'^\s{0,3}>\s?(.*)$')
          .firstMatch(trimmed);
      if (quote != null) {
        flushParagraph();
        blocks.add(
          Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            padding: const EdgeInsets.only(left: AppSpacing.sm),
            decoration: const BoxDecoration(
              border: Border(
                left: BorderSide(color: AppColors.border, width: 3),
              ),
            ),
            child: Text(
              _plainText(quote.group(1)!),
              style: text.bodySmall?.copyWith(
                color: AppColors.inkMuted,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        );
        index += 1;
        continue;
      }

      if (paragraph.isNotEmpty) {
        paragraph.write(' ');
      }
      paragraph.write(trimmed.trim());
      index += 1;
    }
    flushParagraph();
    return blocks;
  }

  /// Inline Markdown that release notes commonly use. Everything it does not
  /// recognise stays literal text, so `<script>` can only ever be characters on
  /// screen. Images are rendered as their alt text: the update surface does not
  /// fetch remote media.
  List<InlineSpan> _parseInline(String source, TextTheme text) {
    final TextStyle base = (text.bodyMedium ?? const TextStyle()).copyWith(
      fontSize: 14,
      height: 1.6,
      color: AppColors.ink,
    );
    final List<InlineSpan> spans = <InlineSpan>[];
    final StringBuffer literal = StringBuffer();

    void flushLiteral() {
      if (literal.isEmpty) {
        return;
      }
      spans.add(TextSpan(text: literal.toString(), style: base));
      literal.clear();
    }

    int index = 0;
    while (index < source.length) {
      final String rest = source.substring(index);
      if (rest.startsWith('`')) {
        final int close = rest.indexOf('`', 1);
        if (close > 0) {
          flushLiteral();
          spans.add(
            TextSpan(
              text: rest.substring(1, close),
              style: base.copyWith(
                fontFamily: 'monospace',
                backgroundColor: AppColors.accentSoft,
              ),
            ),
          );
          index += close + 1;
          continue;
        }
      }
      if (rest.startsWith('**') || rest.startsWith('__')) {
        final String marker = rest.substring(0, 2);
        final int close = rest.indexOf(marker, 2);
        if (close > 0) {
          flushLiteral();
          spans.add(
            TextSpan(
              text: _plainText(rest.substring(2, close)),
              style: base.copyWith(fontWeight: FontWeight.w700),
            ),
          );
          index += close + 2;
          continue;
        }
      }
      // Images first: they share the "[...](" prefix with links.
      final RegExpMatch? image = RegExp(r'^!\[([^\]]*)\]\(([^)\s]+)\)')
          .firstMatch(rest);
      if (image != null) {
        flushLiteral();
        spans.add(
          TextSpan(
            text: '[图片：${_plainText(image.group(1)!.trim())}]',
            style: base.copyWith(color: AppColors.inkMuted),
          ),
        );
        index += image.end;
        continue;
      }
      final RegExpMatch? link = RegExp(r'^\[([^\]]+)\]\(([^)\s]+)\)')
          .firstMatch(rest);
      if (link != null) {
        final String target = _plainText(link.group(2)!);
        if (!_isWebLink(target)) {
          // Only http(s) targets are presented as links. Other schemes
          // (javascript:, file:, intent:, ...) stay literal text: the update
          // surface never turns a release note into something actionable.
          literal.write(link.group(0));
          index += link.end;
          continue;
        }
        flushLiteral();
        final String label = _plainText(link.group(1)!);
        final TextStyle labelStyle = base.copyWith(
          color: AppColors.accentDeep,
          fontWeight: FontWeight.w600,
        );
        final TextStyle targetStyle = base.copyWith(
          color: AppColors.inkMuted,
          fontSize: 12.5,
        );
        final void Function(String url)? opener = onOpenLink;
        if (opener == null) {
          spans.add(TextSpan(text: label, style: labelStyle));
          if (target != label) {
            spans.add(TextSpan(text: '（$target）', style: targetStyle));
          }
        } else {
          // Only an explicit tap reaches the host, which confirms the exact
          // target before opening it in the browser.
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: InkWell(
                onTap: () => opener(target),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        TextSpan(text: label, style: labelStyle),
                        if (target != label)
                          TextSpan(text: '（$target）', style: targetStyle),
                      ],
                    ),
                    style: base,
                  ),
                ),
              ),
            ),
          );
        }
        index += link.end;
        continue;
      }
      literal.write(source[index]);
      index += 1;
    }
    flushLiteral();
    return spans;
  }

  bool _isWebLink(String target) {
    final Uri? uri = Uri.tryParse(target);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  /// Drops control characters that would break layout; everything else,
  /// including HTML tags, is returned as-is so it is displayed literally.
  String _plainText(String value) {
    return value.replaceAll(
      RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'),
      '',
    );
  }
}

class _ListItem extends StatelessWidget {
  const _ListItem({required this.marker, required this.spans, this.style});

  final String marker;
  final List<InlineSpan> spans;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        bottom: AppSpacing.xs,
        left: AppSpacing.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 22, child: Text(marker, style: style)),
          Expanded(
            child: Text.rich(
              TextSpan(style: style, children: spans),
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}
