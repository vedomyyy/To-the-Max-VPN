import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App test harness renders', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('VPN Client')),
        ),
      ),
    );

    expect(find.text('VPN Client'), findsOneWidget);
  });
}
