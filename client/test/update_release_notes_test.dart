import 'package:bb_client/app.dart';
import 'package:bb_client/ui/updates/release_notes_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpNotes(
    WidgetTester tester,
    String body, {
    Size size = const Size(420, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ReleaseNotesView(body: body),
          ),
        ),
      ),
    );
  }

  testWidgets('空正文显示明确占位，不编造更新说明', (WidgetTester tester) async {
    await pumpNotes(tester, '   \n\t ');

    expect(find.text('此版本未提供更新说明'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>(ReleaseNotesView.emptyKey)),
      findsOneWidget,
    );
  });

  testWidgets('HTML 与脚本只作为文字显示，绝不执行', (WidgetTester tester) async {
    const String body =
        '<script>alert("xss")</script>\n'
        '<b>加粗由 Markdown 决定</b>';
    await pumpNotes(tester, body);

    final Iterable<Text> texts = tester.widgetList<Text>(find.byType(Text));
    final String rendered = texts
        .map((Text text) => text.data ?? text.textSpan?.toPlainText() ?? '')
        .join('\n');
    expect(rendered, contains('<script>alert("xss")</script>'));
    expect(rendered, contains('<b>加粗由 Markdown 决定</b>'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('常规 Markdown 结构可读地呈现：标题、列表、粗体、行内代码', (WidgetTester tester) async {
    const String body =
        '## 本次更新\n'
        '- 修复 **登录** 恢复\n'
        '- 新增 `sha256` 校验\n'
        '1. 第一步\n'
        '2. 第二步\n'
        '> 引用说明\n'
        '---\n'
        '结尾段落\n';
    await pumpNotes(tester, body);

    expect(find.text('本次更新'), findsOneWidget);
    expect(find.textContaining('修复'), findsWidgets);
    expect(find.textContaining('sha256'), findsWidgets);
    expect(find.textContaining('结尾段落'), findsWidgets);
    expect(find.text('•'), findsNWidgets(2));
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('围栏代码保留原文并可横向滚动，不吞掉后续正文', (WidgetTester tester) async {
    const String body =
        '```bash\n'
        'flutter build apk --release --split-per-abi\n'
        '```\n'
        '代码之后仍应有正文\n';
    await pumpNotes(tester, body);

    expect(
      find.text('flutter build apk --release --split-per-abi'),
      findsOneWidget,
    );
    expect(find.textContaining('代码之后仍应有正文'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('链接展示目标但不会自动打开，也不会被当作按钮', (WidgetTester tester) async {
    const String body =
        '见 [发布说明](https://github.com/iiishop/BB/releases/tag/v0.1.0)。\n'
        '以及 [javascript 链接](javascript:alert(1))。\n';
    await pumpNotes(tester, body);

    expect(find.textContaining('发布说明'), findsWidgets);
    expect(
      find.textContaining('https://github.com/iiishop/BB/releases/tag/v0.1.0'),
      findsWidgets,
    );
    expect(find.textContaining('javascript:alert(1)'), findsWidgets);
    // No tap target is created for a link: opening it is a separate explicit
    // user action, so a release note cannot navigate the client.
    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(GestureDetector), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('远程图片不加载，仅显示替代文字', (WidgetTester tester) async {
    await pumpNotes(tester, '![截图](https://example.com/shot.png)\n');

    expect(find.textContaining('[图片：截图]'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏长正文不溢出', (WidgetTester tester) async {
    final String body = List<String>.generate(
      40,
      (int index) => '- 第 $index 条：这是一段较长的更新说明，用来检查窄屏换行。',
    ).join('\n');
    await pumpNotes(tester, body, size: const Size(320, 640));

    expect(tester.takeException(), isNull);
    expect(find.text('•'), findsWidgets);
  });
}
