import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/utils/crop_geometry.dart';

/// The maths behind the 44pt crop-corner targets (HIG round 9, V3).
void main() {
  const bounds = Rect.fromLTRB(0, 100, 400, 500); // the picture on screen
  const rect = Rect.fromLTRB(100, 200, 300, 400);

  Rect drag(CropCorner c, Offset d, {double? ratio, Rect from = rect}) =>
      resizeCropRect(rect: from, corner: c, delta: d, bounds: bounds, aspectRatio: ratio);

  group('free aspect', () {
    test('each corner moves, the opposite corner stays', () {
      expect(drag(CropCorner.topLeft, const Offset(-20, 30)), const Rect.fromLTRB(80, 230, 300, 400));
      expect(drag(CropCorner.topRight, const Offset(20, -30)), const Rect.fromLTRB(100, 170, 320, 400));
      expect(drag(CropCorner.bottomLeft, const Offset(10, 10)), const Rect.fromLTRB(110, 200, 300, 410));
      expect(drag(CropCorner.bottomRight, const Offset(-50, 50)), const Rect.fromLTRB(100, 200, 250, 450));
    });

    test('stops at the picture edge and at the 40pt minimum', () {
      expect(drag(CropCorner.topLeft, const Offset(-999, -999)), const Rect.fromLTRB(0, 100, 300, 400));
      expect(drag(CropCorner.bottomRight, const Offset(999, 999)), const Rect.fromLTRB(100, 200, 400, 500));
      expect(drag(CropCorner.bottomRight, const Offset(-999, -999)),
          const Rect.fromLTRB(100, 200, 100 + kCropMinSide, 200 + kCropMinSide));
      expect(drag(CropCorner.topLeft, const Offset(999, 999)),
          const Rect.fromLTRB(300 - kCropMinSide, 400 - kCropMinSide, 300, 400));
    });
  });

  group('fixed aspect (presets and the circle mask)', () {
    test('keeps the ratio whichever axis leads, for every corner', () {
      const wide = Rect.fromLTRB(100, 200, 300, 350); // 4:3
      for (final c in CropCorner.values) {
        for (final d in const [Offset(37, 5), Offset(-37, 5), Offset(4, 29), Offset(4, -29), Offset(-60, -60)]) {
          final r = drag(c, d, ratio: 4 / 3, from: wide);
          expect(r.width / r.height, closeTo(4 / 3, 1e-9), reason: '$c $d');
          // The opposite corner did not move.
          final opposite = CropCorner.values[CropCorner.values.length - 1 - c.index];
          expect(opposite.of(r), opposite.of(wide), reason: '$c $d');
          expect(bounds.expandToInclude(r), bounds, reason: '$c $d stays inside the picture');
        }
      }
    });

    test('1:1 stops when either side reaches the picture edge', () {
      // 200 of room to the right, 100 below: the square stops at 300.
      final r = drag(CropCorner.bottomRight, const Offset(999, 0), ratio: 1);
      expect(r, const Rect.fromLTRB(100, 200, 400, 500));
      final up = drag(CropCorner.topLeft, const Offset(-999, 0), ratio: 1);
      expect(up, const Rect.fromLTRB(0, 100, 300, 400));
    });

    test('neither side goes under the minimum', () {
      final r = drag(CropCorner.bottomRight, const Offset(-999, 0), ratio: 16 / 9);
      expect(r.height, closeTo(kCropMinSide, 1e-9));
      expect(r.width, closeTo(kCropMinSide * 16 / 9, 1e-9));
      final tall = drag(CropCorner.bottomRight, const Offset(-999, 0), ratio: 0.5);
      expect(tall.width, closeTo(kCropMinSide, 1e-9));
      expect(tall.height, closeTo(kCropMinSide * 2, 1e-9));
    });
  });

  group('touch target', () {
    const viewport = Size(400, 600);
    test('44x44 centred on the corner when there is room', () {
      expect(cropHandleTarget(const Offset(100, 200), viewport), const Rect.fromLTWH(78, 178, 44, 44));
    });

    test('slides inside the canvas at an edge, still 44x44 and still over the corner', () {
      for (final corner in const [Offset(0, 0), Offset(400, 600), Offset(0, 600), Offset(400, 0), Offset(10, 595)]) {
        final t = cropHandleTarget(corner, viewport);
        expect(t.size, const Size(44, 44));
        expect((Offset.zero & viewport).expandToInclude(t), Offset.zero & viewport);
        expect(t.inflate(0.001).contains(corner), isTrue);
      }
    });
  });
}
