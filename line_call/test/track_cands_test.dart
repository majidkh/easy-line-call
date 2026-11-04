// Live detection dots: only candidates near the shown frame are painted.
import 'package:flutter_test/flutter_test.dart';
import 'package:line_call/ui/track_overlay.dart' show candsNear;
import 'package:tennis_core/types.dart';

MuseUpdate _update(Map<int, List<Candidate>> cands) =>
    MuseUpdate(99, const [], const [], cands, 0, false);

void main() {
  test('candsNear keeps only frames around the shown one', () {
    final u = _update({
      5: [const Candidate(1, 2, 0.9)],
      8: [const Candidate(3, 4, 0.8)],
      9: [const Candidate(5, 6, 0.7), const Candidate(7, 8, 0.6)],
      12: [const Candidate(9, 9, 0.5)],
    });
    expect(candsNear(u, 9).map((c) => c.x).toList(), [3, 5, 7]);
    expect(candsNear(u, 9, 0).map((c) => c.x).toList(), [5, 7]);
    expect(candsNear(u, 0), isEmpty);
  });
}
