import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Lightweight jailbreak / root detection (batch 7). Signals, not proof: a
/// modified device shows a warning banner in release ("your organisation may
/// block access") — the server decides whether to block. Every probe is
/// injectable so the detector is unit-testable on a desktop.
class DeviceIntegrityProbes {
  /// Does this path exist (file or directory)?
  final bool Function(String path) exists;

  /// Can we create a file inside [dir]? (Sandboxed apps cannot write to
  /// `/private` or `/system`; a jailbroken / rooted one often can.)
  final bool Function(String dir) canWrite;

  /// Can we start a process? (Sandboxed iOS cannot; most rooted Androids can
  /// run `su`.) Null = probe unavailable on this platform.
  final bool Function()? canFork;

  final bool isIOS;
  final bool isAndroid;

  const DeviceIntegrityProbes({
    required this.exists,
    required this.canWrite,
    this.canFork,
    required this.isIOS,
    required this.isAndroid,
  });

  /// Real probes for the running platform.
  factory DeviceIntegrityProbes.platform() => DeviceIntegrityProbes(
        exists: (p) {
          try {
            return FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound;
          } catch (_) {
            return false;
          }
        },
        canWrite: (dir) {
          final probe = File('$dir/.doqto_${DateTime.now().microsecondsSinceEpoch}');
          try {
            probe.writeAsStringSync('x', flush: true);
            probe.deleteSync();
            return true;
          } catch (_) {
            return false;
          }
        },
        canFork: Platform.isIOS
            ? () {
                try {
                  // A stock iOS sandbox refuses to spawn anything.
                  final r = Process.runSync('/bin/sh', const ['-c', 'true']);
                  return r.exitCode == 0;
                } catch (_) {
                  return false;
                }
              }
            : null,
        isIOS: Platform.isIOS,
        isAndroid: Platform.isAndroid,
      );
}

/// Why the device looks modified. Empty = nothing found.
class DeviceIntegrityReport {
  final List<String> findings;
  const DeviceIntegrityReport(this.findings);

  bool get modified => findings.isNotEmpty;

  static const clean = DeviceIntegrityReport([]);

  @override
  String toString() => 'DeviceIntegrityReport($findings)';
}

class DeviceIntegrity {
  DeviceIntegrity._();

  /// Package managers, substrate loaders and shells a stock iPhone never has.
  static const iosPaths = [
    '/Applications/Cydia.app',
    '/Applications/Sileo.app',
    '/Applications/Zebra.app',
    '/Applications/Installer.app',
    '/Library/MobileSubstrate/MobileSubstrate.dylib',
    '/Library/MobileSubstrate/DynamicLibraries',
    '/usr/lib/libhooker.dylib',
    '/usr/libexec/cydia',
    '/usr/sbin/sshd',
    '/usr/bin/ssh',
    '/bin/bash',
    '/bin/sh',
    '/etc/apt',
    '/private/var/lib/apt',
    '/private/var/lib/cydia',
    '/private/var/jb',
    '/var/jb',
  ];

  /// `su` binaries, Superuser / Magisk artefacts.
  static const androidPaths = [
    '/system/app/Superuser.apk',
    '/system/app/SuperSU.apk',
    '/sbin/su',
    '/system/bin/su',
    '/system/xbin/su',
    '/system/sd/xbin/su',
    '/system/bin/failsafe/su',
    '/data/local/xbin/su',
    '/data/local/bin/su',
    '/data/local/su',
    '/su/bin/su',
    '/system/xbin/busybox',
    '/sbin/.magisk',
    '/data/adb/magisk',
    '/data/adb/modules',
  ];

  /// Directories a sandboxed app must not be able to write into.
  static const iosWritableProbes = ['/private', '/'];
  static const androidWritableProbes = ['/system', '/'];

  /// Runs every probe for the platform and reports what fired.
  static DeviceIntegrityReport check(DeviceIntegrityProbes p) {
    final out = <String>[];
    final paths = p.isIOS
        ? iosPaths
        : p.isAndroid
            ? androidPaths
            : const <String>[];
    for (final path in paths) {
      if (p.exists(path)) out.add('path:$path');
    }
    final dirs = p.isIOS
        ? iosWritableProbes
        : p.isAndroid
            ? androidWritableProbes
            : const <String>[];
    for (final dir in dirs) {
      if (p.canWrite(dir)) out.add('writable:$dir');
    }
    final fork = p.canFork;
    if (fork != null && (p.isIOS || p.isAndroid) && fork()) out.add('fork');
    return DeviceIntegrityReport(out);
  }
}

/// Probes used by [deviceIntegrityProvider]; tests override with fakes.
final deviceIntegrityProbesProvider =
    Provider<DeviceIntegrityProbes>((_) => DeviceIntegrityProbes.platform());

/// Runs once per app session, off the first frame. Clean on desktop / web
/// and in widget tests (no platform probes there).
final deviceIntegrityProvider = FutureProvider<DeviceIntegrityReport>((ref) async {
  final probes = ref.watch(deviceIntegrityProbesProvider);
  if (!probes.isIOS && !probes.isAndroid) return DeviceIntegrityReport.clean;
  final report = DeviceIntegrity.check(probes);
  if (report.modified) debugPrint('device integrity: $report');
  return report;
});
