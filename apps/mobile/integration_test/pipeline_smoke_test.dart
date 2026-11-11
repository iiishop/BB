import 'package:bb_mobile/main.dart' as app;
import 'package:bb_mobile/pipeline_smoke_page.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Linux desktop integration coverage for the pipeline smoke surface.
///
/// Run with: flutter test integration_test -d linux
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('launch → Ready → tap → complete, repeatable', (
    WidgetTester tester,
  ) async {
    app.main();
    await tester.pumpAndSettle();

    expect(find.text(PipelineSmokePage.title), findsOneWidget);
    expect(find.text(PipelineSmokePage.readyLabel), findsOneWidget);

    final Finder runButton = find.byKey(PipelineSmokePage.runButtonKey);
    expect(runButton, findsOneWidget);

    await tester.tap(runButton);
    await tester.pumpAndSettle();
    expect(find.text(PipelineSmokePage.completeLabel), findsOneWidget);

    await tester.tap(runButton);
    await tester.pumpAndSettle();
    expect(find.text(PipelineSmokePage.completeLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('launch → Ready → keyboard activation → complete', (
    WidgetTester tester,
  ) async {
    app.main();
    await tester.pumpAndSettle();

    expect(find.text(PipelineSmokePage.readyLabel), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text(PipelineSmokePage.completeLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
