import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/shared/widgets/orex_dialogs.dart';

void main() {
  testWidgets('text controller stays alive for the full dialog route', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showOrexTextInputDialog(
                  context,
                  title: 'Восстановление',
                  hintText: 'Ключ',
                );
              },
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'secret');
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(result, 'secret');
    expect(tester.takeException(), isNull);
  });

  testWidgets('external form controllers survive reverse route animation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final controller = TextEditingController();
                try {
                  await showOrexStatefulFormDialog<String>(
                    context,
                    title: 'Папка',
                    contentBuilder: (_, _) => TextField(
                      controller: controller,
                    ),
                    onSubmit: () => controller.text,
                  );
                } finally {
                  disposeOrexDialogControllers([controller]);
                }
              },
              child: const Text('Форма'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Форма'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'name');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });
}
