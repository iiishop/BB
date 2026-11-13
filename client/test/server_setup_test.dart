import 'dart:io';

import 'package:bb_client/main.dart';
import 'package:bb_client/services/server_address_store.dart';
import 'package:bb_client/ui/server_setup_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: child);

/// Settles the submit future without `pumpAndSettle`: the busy button shows a
/// progress indicator, so waiting for "no more frames" would never return.
Future<void> _settleSubmit(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('ServerSetupPage', () {
    testWidgets('a first launch asks for an address and submits a bare domain over HTTPS', (
      WidgetTester tester,
    ) async {
      Uri? submitted;
      await tester.pumpWidget(
        _wrap(
          ServerSetupPage(
            onSubmit: (Uri address) async => submitted = address,
          ),
        ),
      );

      expect(find.text('连接到服务器'), findsOneWidget);
      expect(find.byKey(ServerSetupPage.cancelButtonKey), findsNothing);

      await tester.enterText(
        find.byKey(ServerSetupPage.addressFieldKey),
        'bb.iiishop.top',
      );
      await tester.tap(find.byKey(ServerSetupPage.submitButtonKey));
      await _settleSubmit(tester);

      expect(submitted.toString(), 'https://bb.iiishop.top');
    });

    testWidgets('a LAN address is submitted over plain HTTP', (
      WidgetTester tester,
    ) async {
      Uri? submitted;
      await tester.pumpWidget(
        _wrap(
          ServerSetupPage(
            onSubmit: (Uri address) async => submitted = address,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(ServerSetupPage.addressFieldKey),
        '192.168.0.104:18980',
      );
      await tester.tap(find.byKey(ServerSetupPage.submitButtonKey));
      await _settleSubmit(tester);

      expect(submitted.toString(), 'http://192.168.0.104:18980');
    });

    testWidgets('an unsupported scheme is rejected without submitting', (
      WidgetTester tester,
    ) async {
      bool submitted = false;
      await tester.pumpWidget(
        _wrap(
          ServerSetupPage(
            onSubmit: (Uri address) async => submitted = true,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(ServerSetupPage.addressFieldKey),
        'ftp://bb.example.com',
      );
      await tester.tap(find.byKey(ServerSetupPage.submitButtonKey));
      await _settleSubmit(tester);

      expect(submitted, isFalse);
      expect(find.textContaining('http'), findsWidgets);
    });

    testWidgets('an empty address is rejected', (WidgetTester tester) async {
      bool submitted = false;
      await tester.pumpWidget(
        _wrap(
          ServerSetupPage(
            onSubmit: (Uri address) async => submitted = true,
          ),
        ),
      );

      await tester.tap(find.byKey(ServerSetupPage.submitButtonKey));
      await _settleSubmit(tester);

      expect(submitted, isFalse);
    });

    testWidgets('a save failure is shown instead of leaving the screen silently', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          ServerSetupPage(
            onSubmit: (Uri address) async => throw const FileSystemException('disk'),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(ServerSetupPage.addressFieldKey),
        'bb.iiishop.top',
      );
      await tester.tap(find.byKey(ServerSetupPage.submitButtonKey));
      await _settleSubmit(tester);

      expect(find.byKey(ServerSetupPage.errorBannerKey), findsOneWidget);
    });

    testWidgets('changing an existing address offers cancel and prefills it', (
      WidgetTester tester,
    ) async {
      bool cancelled = false;
      await tester.pumpWidget(
        _wrap(
          ServerSetupPage(
            initialAddress: Uri.parse('https://bb.iiishop.top'),
            changing: true,
            onSubmit: (Uri address) async {},
            onCancel: () => cancelled = true,
          ),
        ),
      );

      expect(find.text('更换服务器'), findsOneWidget);
      final TextFormField field = tester.widget<TextFormField>(
        find.descendant(
          of: find.byKey(ServerSetupPage.addressFieldKey),
          matching: find.byType(TextFormField),
        ),
      );
      expect(field.controller?.text, 'https://bb.iiishop.top');

      await tester.tap(find.byKey(ServerSetupPage.cancelButtonKey));
      await _settleSubmit(tester);
      expect(cancelled, isTrue);
    });
  });

  group('BbRoot', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('bb-root');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    testWidgets('no compiled address and no saved address shows the setup screen', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        BbRoot(
          sessionFile: File('${root.path}/session.json'),
          addressStore: ServerAddressStore(File('${root.path}/server.json')),
          compiledAddress: null,
        ),
      );
      // The address read is real file IO, so let it settle outside the fake
      // clock before asserting the screen.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();

      expect(find.byKey(ServerSetupPage.addressFieldKey), findsOneWidget);
      expect(find.text('连接到服务器'), findsOneWidget);
    });
  });
}
