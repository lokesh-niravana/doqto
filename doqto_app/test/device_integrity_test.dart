import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/security/device_integrity.dart';

DeviceIntegrityProbes _probes({
  Set<String> existing = const {},
  Set<String> writable = const {},
  bool? fork,
  bool ios = true,
}) =>
    DeviceIntegrityProbes(
      exists: existing.contains,
      canWrite: writable.contains,
      canFork: fork == null ? null : () => fork,
      isIOS: ios,
      isAndroid: !ios,
    );

void main() {
  test('a stock iPhone reports clean', () {
    final r = DeviceIntegrity.check(_probes(fork: false));
    expect(r.modified, isFalse);
    expect(r.findings, isEmpty);
  });

  test('Cydia / Sileo paths flag a jailbreak', () {
    final r = DeviceIntegrity.check(_probes(existing: {'/Applications/Sileo.app'}, fork: false));
    expect(r.modified, isTrue);
    expect(r.findings, ['path:/Applications/Sileo.app']);
  });

  test('a writable /private flags a jailbreak', () {
    final r = DeviceIntegrity.check(_probes(writable: {'/private'}, fork: false));
    expect(r.findings, ['writable:/private']);
  });

  test('being able to fork a shell flags a jailbreak', () {
    final r = DeviceIntegrity.check(_probes(fork: true));
    expect(r.findings, ['fork']);
  });

  test('su binaries and Magisk flag a rooted Android; iOS paths are ignored there', () {
    final r = DeviceIntegrity.check(_probes(
      ios: false,
      existing: {'/system/xbin/su', '/sbin/.magisk', '/Applications/Cydia.app'},
    ));
    expect(r.findings, ['path:/system/xbin/su', 'path:/sbin/.magisk']);
  });

  test('several findings are all reported', () {
    final r = DeviceIntegrity.check(_probes(
      existing: {'/bin/bash', '/etc/apt'},
      writable: {'/private'},
      fork: true,
    ));
    expect(r.findings, ['path:/bin/bash', 'path:/etc/apt', 'writable:/private', 'fork']);
  });

  test('desktop and tests report clean without probing', () async {
    final c = ProviderContainer(overrides: [
      deviceIntegrityProbesProvider.overrideWithValue(
        DeviceIntegrityProbes(
          exists: (_) => true,
          canWrite: (_) => true,
          canFork: () => true,
          isIOS: false,
          isAndroid: false,
        ),
      ),
    ]);
    addTearDown(c.dispose);
    expect((await c.read(deviceIntegrityProvider.future)).modified, isFalse);
  });

  test('the provider runs the probes on a phone', () async {
    final c = ProviderContainer(overrides: [
      deviceIntegrityProbesProvider.overrideWithValue(_probes(existing: {'/var/jb'}, fork: false)),
    ]);
    addTearDown(c.dispose);
    expect((await c.read(deviceIntegrityProvider.future)).findings, ['path:/var/jb']);
  });
}
