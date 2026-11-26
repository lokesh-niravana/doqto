import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/api_routes.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/repositories/user_repository.dart';

/// PATCH /users/me: a field left out keeps its value on the server
/// (`exclude_unset`), so a value the user removed has to go as an explicit
/// null. Without it the save "succeeds" and the old value stays.
class _Api extends ApiClient {
  final calls = <(String, Object?)>[];

  @override
  Future<Map<String, dynamic>> patch(String path, {Object? body}) async {
    calls.add((path, body));
    return {
      'id': 'me',
      'phone': '+15550000101',
      'full_name': 'Dr A',
      'role': 'doctor',
      'created_at': '2026-09-05T00:00:00Z',
    };
  }
}

void main() {
  test('a field that is not set is left out of the body', () {
    final json = const UserPatchBody(fullName: 'Dr A').toJson();
    expect(json, {'full_name': 'Dr A'});
    expect(json.containsKey('email'), isFalse);
    expect(json.containsKey('years_of_experience'), isFalse);
  });

  test('cleared fields are sent as explicit nulls', () {
    final json = const UserPatchBody(
      fullName: 'Dr A',
      clear: {
        UserPatchBody.clearEmail,
        UserPatchBody.clearYearsOfExperience,
      },
    ).toJson();
    expect(json.containsKey('email'), isTrue);
    expect(json['email'], isNull);
    expect(json.containsKey('years_of_experience'), isTrue);
    expect(json['years_of_experience'], isNull);
    expect(json['full_name'], 'Dr A');
  });

  test('a new value wins over a clear of the same field', () {
    final json = const UserPatchBody(
      email: 'a@clinic.com',
      yearsOfExperience: 12,
      clear: {
        UserPatchBody.clearEmail,
        UserPatchBody.clearYearsOfExperience,
      },
    ).toJson();
    expect(json['email'], 'a@clinic.com');
    expect(json['years_of_experience'], 12);
  });

  test('updateMe sends the nulls to PATCH /users/me', () async {
    final api = _Api();
    await UserRepository(api).updateMe(const UserPatchBody(
      fullName: 'Dr A',
      clear: {UserPatchBody.clearYearsOfExperience},
    ));
    final (path, body) = api.calls.single;
    expect(path, ApiRoutes.usersMe);
    final map = body as Map<String, dynamic>;
    expect(map.containsKey('years_of_experience'), isTrue);
    expect(map['years_of_experience'], isNull);
    expect(map.containsKey('email'), isFalse);
  });
}
