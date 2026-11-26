import 'dart:math' as math;
import 'dart:ui';

/// A corner of the crop rectangle.
enum CropCorner {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight;

  bool get isLeft => this == topLeft || this == bottomLeft;
  bool get isTop => this == topLeft || this == topRight;

  /// Where this corner sits on [rect].
  Offset of(Rect rect) => Offset(
        isLeft ? rect.left : rect.right,
        isTop ? rect.top : rect.bottom,
      );
}

/// Shortest side a crop rectangle may be dragged down to — the same floor
/// crop_your_image's own corner handles use.
const double kCropMinSide = 40;

/// Side of a corner handle's touch target.
const double kCropHandleTarget = 44;

/// [rect] after its [corner] has been dragged by [delta] (the whole drag so
/// far, measured from where [rect] was when the drag began). The opposite
/// corner stays put.
///
/// The result never leaves [bounds] (the part of the picture on screen) and
/// never gets smaller than [kCropMinSide] a side, unless [bounds] itself
/// leaves no room for that. With an [aspectRatio] (width / height; 1 for the
/// circle mask) the shape is kept: the larger of the two drag axes drives the
/// size and the other follows.
Rect resizeCropRect({
  required Rect rect,
  required CropCorner corner,
  required Offset delta,
  required Rect bounds,
  double? aspectRatio,
}) {
  final left = corner.isLeft;
  final top = corner.isTop;
  // The corner that does not move.
  final ax = left ? rect.right : rect.left;
  final ay = top ? rect.bottom : rect.top;
  // Room between that corner and the edge of the picture it grows towards.
  final maxW = left ? ax - bounds.left : bounds.right - ax;
  final maxH = top ? ay - bounds.top : bounds.bottom - ay;
  if (maxW <= 0 || maxH <= 0) return rect;

  // Dragging outwards grows the rect: leftwards for a left corner, and so on.
  final growX = left ? -delta.dx : delta.dx;
  final growY = top ? -delta.dy : delta.dy;

  double w, h;
  final ratio = aspectRatio;
  if (ratio == null || ratio <= 0) {
    w = (rect.width + growX).clamp(math.min(kCropMinSide, maxW), maxW);
    h = (rect.height + growY).clamp(math.min(kCropMinSide, maxH), maxH);
  } else {
    w = delta.dx.abs() >= delta.dy.abs()
        ? rect.width + growX
        : (rect.height + growY) * ratio;
    // Both sides inside the picture, both at least the minimum.
    final most = math.min(maxW, maxH * ratio);
    final least = math.min(math.max(kCropMinSide, kCropMinSide * ratio), most);
    w = w.clamp(least, most);
    h = w / ratio;
  }
  return Rect.fromLTWH(left ? ax - w : ax, top ? ay - h : ay, w, h);
}

/// The [kCropHandleTarget]-square touch target for a handle at [corner],
/// centred on it where there is room and slid inwards where the corner is
/// within half a target of the [viewport] edge — a target hanging outside
/// the canvas could not be touched there.
Rect cropHandleTarget(Offset corner, Size viewport) {
  double along(double c, double extent) {
    final max = extent - kCropHandleTarget;
    if (max <= 0) return 0;
    return (c - kCropHandleTarget / 2).clamp(0.0, max);
  }

  return Rect.fromLTWH(
    along(corner.dx, viewport.width),
    along(corner.dy, viewport.height),
    kCropHandleTarget,
    kCropHandleTarget,
  );
}
