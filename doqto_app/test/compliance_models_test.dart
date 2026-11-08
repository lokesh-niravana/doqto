import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/models/compliance.dart';
import 'package:doqto_app/data/models/organization.dart';

void main() {
  test('OrgPolicies parses every batch-7 key and keeps server defaults', () {
    final p = OrgPolicies.fromJson({
      'allow_forward_outside_org': false,
      'allow_copy': false,
      'allow_media_export': true,
      'block_screenshots': true,
      'show_preview_in_banners_default': true,
      'default_disappear_sec': 604800,
      'retention_days': 90,
      'legal_hold': true,
    });
    expect(p.allowForwardOutsideOrg, isFalse);
    expect(p.allowCopy, isFalse);
    expect(p.allowMediaExport, isTrue);
    expect(p.blockScreenshots, isTrue);
    expect(p.showPreviewInBannersDefault, isTrue);
    expect(p.defaultDisappearSec, 604800);
    expect(p.retentionDays, 90);
    expect(p.legalHold, isTrue);
    expect(p.toJson()['retention_days'], 90);

    final d = OrgPolicies.fromJson(null);
    expect(d.allowCopy, isTrue);
    expect(d.allowMediaExport, isFalse);
    expect(d.retentionDays, isNull);
    expect(d.legalHold, isFalse);
    // apply(): null clears a nullable int.
    expect(p.apply({'retention_days': null}).retentionDays, isNull);
    expect(p.apply({'allow_copy': true}).allowCopy, isTrue);
  });

  test('AccessRequest: readable only while approved and inside the window', () {
    final base = {
      'id': 'r1',
      'org_id': 'o1',
      'conversation_id': 'c1',
      'requester_id': 'u1',
      'reason': 'audit',
      'created_at': '2026-11-01T00:00:00Z',
    };
    final future = DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String();
    final past = DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String();
    expect(AccessRequest.fromJson({...base, 'status': 'approved', 'expires_at': future}).readable, isTrue);
    expect(AccessRequest.fromJson({...base, 'status': 'approved', 'expires_at': past}).readable, isFalse);
    expect(AccessRequest.fromJson({...base, 'status': 'pending'}).readable, isFalse);
    expect(AccessRequest.fromJson({...base, 'status': 'bogus'}).status, AccessRequestStatus.pending);
    expect(AccessRequest.fromJson({...base, 'status': 'expired'}).status, AccessRequestStatus.expired);
  });

  test('OrgReport parses ids, reason and status; never a body', () {
    final r = OrgReport.fromJson({
      'id': 'rep1',
      'reporter_id': 'u1',
      'subject_type': 'message',
      'subject_id': 'm1',
      'reason': 'phi_misuse',
      'details': 'shared a chart',
      'status': 'reviewing',
      'context_message_ids': ['m1', 'm2'],
      'created_at': '2026-11-01T00:00:00Z',
    });
    expect(r.reason, ReportReason.phiMisuse);
    expect(r.status, ReportStatus.reviewing);
    expect(r.contextMessageIds, ['m1', 'm2']);
    expect(r.copyWith(status: ReportStatus.actioned).status, ReportStatus.actioned);
    expect(ReportStatus.fromWire('nope'), ReportStatus.open);
  });

  test('ScheduledMessage parses without content', () {
    final s = ScheduledMessage.fromJson({
      'id': 's1',
      'conversation_id': 'c1',
      'scheduled_at': '2026-11-09T09:00:00Z',
      'timezone': 'America/Los_Angeles',
      'status': 'failed',
      'error': 'rate_limited',
      'created_at': '2026-11-08T00:00:00Z',
    });
    expect(s.failed, isTrue);
    expect(s.error, 'rate_limited');
    expect(s.scheduledAt.isUtc, isTrue);
  });
}
