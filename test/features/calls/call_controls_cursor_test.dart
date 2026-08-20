import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/features/calls/call_controls.dart';

void main() {
  testWidgets('call control uses the click cursor on desktop', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OrexCallControlButton(
            icon: Icons.mic,
            style: OrexCallControlButtonStyle.full,
            selected: false,
            onTap: () {},
          ),
        ),
      ),
    );

    final ink = tester.widget<InkResponse>(find.byType(InkResponse));
    expect(ink.mouseCursor, SystemMouseCursors.click);
  });
}
