// Home page fits small phone screens (landscape or portrait) with no
// overflow: compact sizes kick in when either dimension drops under 500.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:line_call/ui/home_page.dart';

void main() {
  Future<void> pumpHome(WidgetTester tester, Size logical) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = logical * 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
        const MaterialApp(home: HomePage()));
  }

  testWidgets('home fits landscape phone', (tester) async {
    await pumpHome(tester, const Size(844, 390));
    await tester.pump();
    expect(find.text('Easy Line Call'), findsOneWidget);
    expect(find.text('process video'), findsOneWidget);
    expect(find.text('live feed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home fits portrait phone', (tester) async {
    await pumpHome(tester, const Size(390, 844));
    await tester.pump();
    expect(find.text('Easy Line Call'), findsOneWidget);
    expect(find.text('process video'), findsOneWidget);
    expect(find.text('live feed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
