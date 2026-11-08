import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/enums/app_enums.dart';

/// What a sign-in tells the server about this device (batch 6, linked
/// devices): a model name, the platform and the app version. A device model
/// is not PHI. Read once through the `doqto/device` method channel
/// (AppDelegate / MainActivity) — no device_info_plus dependency.
class DeviceDescription {
  final String? deviceName;
  final DevicePlatform platform;
  final String? appVersion;

  const DeviceDescription({
    required this.deviceName,
    required this.platform,
    required this.appVersion,
  });

  Map<String, dynamic> toJson() => {
        'device_name': ?deviceName,
        'platform': platform.wire,
        'app_version': ?appVersion,
      };
}

abstract class DeviceInfo {
  Future<DeviceDescription> describe();

  /// "1.0.0+45" — pubspec form, compared against `GET /app/min-version`.
  Future<String> appVersion();
}

class PlatformDeviceInfo implements DeviceInfo {
  static const _channel = MethodChannel('doqto/device');

  /// Platform channels never answer in a widget test (no host), so every
  /// call is time-boxed; sign-in must not wait on a device label.
  static const _timeout = Duration(seconds: 2);
  DeviceDescription? _cached;
  String? _version;

  @override
  Future<String> appVersion() async {
    if (_version != null) return _version!;
    try {
      final info = await PackageInfo.fromPlatform().timeout(_timeout);
      _version = '${info.version}+${info.buildNumber}';
    } catch (_) {
      _version = '';
    }
    return _version!;
  }

  @override
  Future<DeviceDescription> describe() async {
    final cached = _cached;
    if (cached != null) return cached;
    String? name;
    try {
      name = await _channel.invokeMethod<String>('name').timeout(_timeout);
    } catch (_) {
      name = null;
    }
    final version = await appVersion();
    final d = DeviceDescription(
      deviceName: (name == null || name.trim().isEmpty) ? null : name.trim(),
      platform: Platform.isIOS ? DevicePlatform.ios : DevicePlatform.android,
      appVersion: version.isEmpty ? null : version,
    );
    _cached = d;
    return d;
  }
}

/// Test double.
class FakeDeviceInfo implements DeviceInfo {
  FakeDeviceInfo({
    this.name = 'Test iPhone',
    this.platform = DevicePlatform.ios,
    this.version = '1.0.0+45',
  });
  final String? name;
  final DevicePlatform platform;
  final String version;

  @override
  Future<String> appVersion() async => version;

  @override
  Future<DeviceDescription> describe() async => DeviceDescription(
        deviceName: name,
        platform: platform,
        appVersion: version,
      );
}
