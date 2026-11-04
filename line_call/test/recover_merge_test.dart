// Recovery merge: repeat ROI finds must not pile duplicate candidates onto
// a frame (rally-3.mov: re-search rounds appended the same ghost 4-6x per
// frame, fragmenting tracks and shifting bounce fires).
import 'package:flutter_test/flutter_test.dart';
import 'package:tennis_core/src/recover.dart' show mergeFound;
import 'package:tennis_core/types.dart';

void main() {
  test('mergeFound skips hits within 2px of an existing candidate', () {
    final fc = <int, List<Candidate>>{
      1252: [const Candidate(938.8, 485.9, 0.9)],
    };
    final n = mergeFound(fc, {
      1252: [(938.8, 485.9, 0.8), (939.5, 486.4, 0.9)],
    });
    expect(n, 0);
    expect(fc[1252]!.length, 1);
  });

  test('mergeFound appends novel hits and counts only those', () {
    final fc = <int, List<Candidate>>{
      1252: [const Candidate(938.8, 485.9, 0.9)],
    };
    final n = mergeFound(fc, {
      1252: [(950.4, 526.2, 0.8)],
      1253: [(952.6, 528.0, 0.7)],
    });
    expect(n, 2);
    expect(fc[1252]!.length, 2);
    expect(fc[1253]!.length, 1);
  });
}
