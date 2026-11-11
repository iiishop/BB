import 'package:bb_client/app.dart';
import 'package:bb_client/pipeline_smoke_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Linux desktop coverage of the pipeline smoke surface, kept from the
/// skeleton so the migration does not drop it.
///
/// Registered from `auth_flow_test.dart`: the Linux desktop device cannot start
/// a second application inside one `flutter test` invocation, so all desktop
/// integration cases run in a single `*_test.dart` file.
void registerPipelineSmokeIntegrationTests() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpSmokePage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: buildAppTheme(), home: const PipelineSmokePage()),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('launch → Ready → tap → complete, repeatable', (
    WidgetTester tester,
  ) async {
    await pumpSmokePage(tester);

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
    await pumpSmokePage(tester);

    expect(find.text(PipelineSmokePage.readyLabel), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text(PipelineSmokePage.completeLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
