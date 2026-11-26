import 'package:doqto_app/core/utils/validators.dart';
import 'package:doqto_app/state/settings_state.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppTextScaler', () {
    AppTextScaler scaler(AppFontSize size, [double system = 1]) =>
        AppTextScaler(system: TextScaler.linear(system), factor: size.factor);

    test('Small never takes text below 11pt at system scale 1.0', () {
      final s = scaler(AppFontSize.small);
      expect(s.scale(11), 11);
      expect(s.scale(12), 11); // 10.8 without the floor
      expect(s.scale(13), closeTo(11.7, 1e-9));
      expect(s.scale(16), closeTo(14.4, 1e-9));
      for (var size = 11.0; size <= 40; size += 0.5) {
        expect(s.scale(size), greaterThanOrEqualTo(11), reason: '$size');
      }
    });

    test('text already under 11pt is left alone, not enlarged or shrunk', () {
      expect(scaler(AppFontSize.small).scale(10), 10);
    });

    test('the floor follows the system scale', () {
      final s = scaler(AppFontSize.small, 2);
      expect(s.scale(11), 22);
      expect(s.scale(12), 22);
      expect(s.scale(16), closeTo(28.8, 1e-9));
    });

    test('Medium and Large multiply the system scale, as before', () {
      expect(scaler(AppFontSize.medium, 1.5).scale(12), 18);
      expect(scaler(AppFontSize.large).scale(11), closeTo(12.65, 1e-9));
      expect(scaler(AppFontSize.large, 2).scale(10), closeTo(23, 1e-9));
    });

    test('clamping still caps fixed-height controls', () {
      final s = scaler(AppFontSize.large, 2).clamp(maxScaleFactor: 1.3);
      expect(s.scale(10), closeTo(13, 1e-9));
    });

    test('equal when system and factor are equal', () {
      expect(scaler(AppFontSize.small), scaler(AppFontSize.small));
      expect(scaler(AppFontSize.small), isNot(scaler(AppFontSize.medium)));
      expect(scaler(AppFontSize.small), isNot(scaler(AppFontSize.small, 1.2)));
    });
  });

  group('Validators.pin', () {
    final v = Validators.pin(6);
    test('says PIN, not "the code we sent you"', () {
      expect(v(''), 'Enter your 6-digit PIN.');
      expect(v('123'), 'Enter your 6-digit PIN.');
      expect(v('12a456'), 'Enter your 6-digit PIN.');
      expect(Validators.pin(4)('1'), 'Enter your 4-digit PIN.');
    });
    test('passes a full PIN', () => expect(v('123456'), isNull));
  });
}
