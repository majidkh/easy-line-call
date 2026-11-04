// Bounce call rule: outside the boundary = OUT (red), on the line or
// inside = IN (green), judged on the singles or doubles sidelines per
// the calibrated court. A 6 cm grace past the line keeps line touches IN.
import 'package:flutter_test/flutter_test.dart';
import 'package:line_call/ui/track_overlay.dart' show bounceIsIn;
import 'package:tennis_core/types.dart' show BounceCall;

BounceCall _at(double wx, double wy) =>
    BounceCall(0, 0, 0, 'IN', wx, wy);

void main() {
  test('center and inside are IN in both modes', () {
    expect(bounceIsIn(_at(0, 0), doubles: true), isTrue);
    expect(bounceIsIn(_at(0, 0), doubles: false), isTrue);
    expect(bounceIsIn(_at(-3.2, -5.0), doubles: true), isTrue);
    expect(bounceIsIn(_at(-3.2, -5.0), doubles: false), isTrue);
  });

  test('outside the doubles court is OUT in both modes', () {
    // Past the doubles sideline (5.485) and past the baseline (11.885).
    expect(bounceIsIn(_at(6.0, 0), doubles: true), isFalse);
    expect(bounceIsIn(_at(6.0, 0), doubles: false), isFalse);
    expect(bounceIsIn(_at(0, 12.5), doubles: true), isFalse);
    expect(bounceIsIn(_at(0, 12.5), doubles: false), isFalse);
    // Neighboring court, far outside.
    expect(bounceIsIn(_at(14.0, 3.0), doubles: true), isFalse);
    expect(bounceIsIn(_at(14.0, 3.0), doubles: false), isFalse);
  });

  test('singles sidelines judge the tramlines OUT only in singles', () {
    // Between the singles (4.115) and doubles (5.485) sidelines.
    expect(bounceIsIn(_at(4.8, 0), doubles: true), isTrue);
    expect(bounceIsIn(_at(4.8, 0), doubles: false), isFalse);
    expect(bounceIsIn(_at(-4.8, 0), doubles: true), isTrue);
    expect(bounceIsIn(_at(-4.8, 0), doubles: false), isFalse);
  });

  test('on the line and line touches are IN', () {
    // Exactly on the doubles sideline / baseline.
    expect(bounceIsIn(_at(5.485, 0), doubles: true), isTrue);
    expect(bounceIsIn(_at(0, 11.885), doubles: true), isTrue);
    // Touching the line: 5 cm past still IN, 7 cm past OUT.
    expect(bounceIsIn(_at(5.485 + 0.05, 0), doubles: true), isTrue);
    expect(bounceIsIn(_at(5.485 + 0.07, 0), doubles: true), isFalse);
  });
}
