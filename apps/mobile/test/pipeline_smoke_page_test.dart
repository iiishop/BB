import 'package:bb_mobile/app.dart';
import 'package:bb_mobile/pipeline_smoke_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(const BbMobileApp());
  await tester.pumpAndSettle();
}

Finder get runButton => find.byKey(PipelineSmokePage.runButtonKey);

void main() {
  testWidgets('first launch shows the title, Ready status and the action', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    expect(find.text(PipelineSmokePage.title), findsOneWidget);
    expect(find.text(PipelineSmokePage.readyLabel), findsOneWidget);
    expect(find.text(PipelineSmokePage.runLabel), findsOneWidget);
    expect(runButton, findsOneWidget);
    expect(find.text(PipelineSmokePage.completeLabel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('activating the action shows the completion status', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(runButton);
    await tester.pumpAndSettle();

    expect(find.text(PipelineSmokePage.completeLabel), findsOneWidget);
    expect(find.text(PipelineSmokePage.readyLabel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the action can be activated repeatedly without errors', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    for (var i = 0; i < 3; i++) {
      await tester.tap(runButton);
      await tester.pumpAndSettle();
    }

    expect(find.text(PipelineSmokePage.completeLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the action has an accessible name and the status is a live '
      'region', (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await pumpApp(tester);

    expect(
      tester.getSemantics(runButton),
      isSemantics(
        label: PipelineSmokePage.runLabel,
        isButton: true,
        isEnabled: true,
        hasTapAction: true,
        isFocusable: true,
        hasFocusAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.text(PipelineSmokePage.title)),
      isSemantics(label: PipelineSmokePage.title, isHeader: true),
    );
    expect(
      tester.getSemantics(find.text(PipelineSmokePage.readyLabel)),
      isSemantics(
        label: 'Status: ${PipelineSmokePage.readyLabel}',
        isLiveRegion: true,
      ),
    );

    await tester.tap(runButton);
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.text(PipelineSmokePage.completeLabel)),
      isSemantics(
        label: 'Status: ${PipelineSmokePage.completeLabel}',
        isLiveRegion: true,
      ),
    );

    handle.dispose();
  });

  testWidgets('the action is keyboard operable with Enter', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    expect(FocusManager.instance.primaryFocus, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text(PipelineSmokePage.completeLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the action is keyboard operable with Space', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();

    expect(find.text(PipelineSmokePage.completeLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders and completes without overflow on a compact phone '
      'viewport', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpApp(tester);
    // debug: expect(tester.takeException(), isNull);

    await tester.ensureVisible(runButton);
    await tester.tap(runButton);
    await tester.pumpAndSettle();

    expect(find.text(PipelineSmokePage.completeLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
