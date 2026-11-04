import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:line_call/main.dart';
import 'package:line_call/ui/calibrate_page.dart';

void main() {
  testWidgets('home shows the title and both feeds',
      (tester) async {
    await tester.pumpWidget(const LineCallApp());
    await tester.pumpAndSettle();

    expect(find.text('Easy Line Call'), findsOneWidget);
    expect(find.text('process video'), findsOneWidget);
    expect(find.text('live feed'), findsOneWidget);
  });

  testWidgets('live feed opens calibration', (tester) async {
    await tester.pumpWidget(const LineCallApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('live feed'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Calibrate live feed'), findsOneWidget);
    expect(find.text('Calibrate'), findsOneWidget);
    expect(find.byType(Slider), findsNothing); // live has no scrub slider
  });

  testWidgets('video calibration is full-bleed with overlay controls',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: CalibratePage.video(videoPath: 'missing.mp4')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Single title in the AppBar; no duplicate overlay label.
    expect(find.text('Court detection'), findsOneWidget);
    expect(find.text('Pick a frame'), findsNothing);
    expect(find.text('Calibrate'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    // Slider spans the bottom, full width.
    final sliderTop =
        tester.getTopLeft(find.byType(Slider)).dy;
    final sliderLeft =
        tester.getTopLeft(find.byType(Slider)).dx;
    final sliderRight =
        tester.getTopRight(find.byType(Slider)).dx;
    final size = tester.getSize(find.byType(Scaffold));
    expect(sliderTop, greaterThan(size.height - 120));
    expect(sliderLeft, lessThan(60));
    expect(sliderRight, greaterThan(size.width - 120));
  });

  testWidgets('court format selection reaches calibration',
      (tester) async {
    await tester.pumpWidget(const LineCallApp());
    await tester.pumpAndSettle();

    // Default is doubles.
    expect(find.text('Doubles'), findsOneWidget);

    // Switch to singles, then open the live flow.
    await tester.tap(find.text('Doubles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Singles').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('live feed'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final page =
        tester.widget<CalibratePage>(find.byType(CalibratePage));
    expect(page.doubles, isFalse);
  });
}
