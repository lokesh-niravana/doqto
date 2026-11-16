import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/token_storage.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/models/organization.dart';
import 'package:doqto_app/data/repositories/auth_repository.dart';
import 'package:doqto_app/data/repositories/org_repository.dart';
import 'package:doqto_app/data/repositories/user_repository.dart';
import 'package:doqto_app/state/auth_state.dart';

// `POST /auth/register` has no city/state and silently drops them, so the
// practice location from the NPI registry is saved with `PATCH /users/me`
// afterwards — and a failure there must never undo a successful registration.

User _user({String? city}) => User.fromJson({
      'id': 'u1',
      'phone': '+15555550100',
      'full_name': 'Vimal Nanavati',
      'npi_number': '1851408082',
      'role': 'doctor',
      'city': city,
      'created_at': DateTime.now().toIso8601String(),
    });

class _Auth extends AuthRepository {
  _Auth() : super(ApiClient(), TokenStorage());
  @override
  Future<User> register({
    required String fullName,
    required String? specialty,
    required String npiNumber,
  }) async =>
      _user();
}

/// No org yet: registration ends straight in the app.
class _Orgs extends OrgRepository {
  _Orgs() : super(ApiClient());
  @override
  Future<List<Organization>> listMine() async => [];
}

class _Users extends UserRepository {
  _Users({this.fail = false}) : super(ApiClient());
  final bool fail;
  final List<Map<String, dynamic>> patches = [];

  @override
  Future<User> updateMe(UserPatchBody patch) async {
    patches.add(patch.toJson());
    if (fail) throw ApiException('down', status: 503);
    return _user(city: patch.city);
  }
}

ProviderContainer _container(_Users users) {
  final c = ProviderContainer(overrides: [
    authRepositoryProvider.overrideWithValue(_Auth()),
    userRepositoryProvider.overrideWithValue(users),
    orgRepositoryProvider.overrideWithValue(_Orgs()),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('a practice location is saved through the profile', () async {
    final users = _Users();
    final c = _container(users);

    await c.read(authProvider.notifier).completeRegistration(
          fullName: 'Vimal Nanavati',
          npiNumber: '1851408082',
          city: 'Bonita',
          practiceState: 'CA',
        );

    expect(users.patches.single, {'city': 'Bonita', 'state': 'CA'});
    expect(c.read(authProvider).user?.city, 'Bonita');
    expect(c.read(authProvider).stage, AuthStage.signedIn);
  });

  test('no location, no profile call', () async {
    final users = _Users();
    final c = _container(users);

    await c.read(authProvider.notifier).completeRegistration(
          fullName: 'Vimal Nanavati',
          npiNumber: '1851408082',
        );

    expect(users.patches, isEmpty);
    expect(c.read(authProvider).stage, AuthStage.signedIn);
  });

  test('a failed location save still completes registration', () async {
    final users = _Users(fail: true);
    final c = _container(users);

    await c.read(authProvider.notifier).completeRegistration(
          fullName: 'Vimal Nanavati',
          npiNumber: '1851408082',
          city: 'Bonita',
          practiceState: 'CA',
        );

    expect(users.patches, hasLength(1));
    expect(c.read(authProvider).stage, AuthStage.signedIn);
    expect(c.read(authProvider).user?.fullName, 'Vimal Nanavati');
  });
}
