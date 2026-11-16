import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/security/certificate_pinning.dart';

/// DER of a PEM certificate.
Uint8List _der(String pem) {
  final b64 = pem
      .split('\n')
      .where((l) => l.isNotEmpty && !l.startsWith('-----'))
      .join();
  return Uint8List.fromList(base64.decode(b64));
}

void main() {
  final leafPem = File('test/fixtures/api_doqto_ai_leaf.pem').readAsStringSync();

  test('leaf SPKI pin matches the value openssl computes for the live cert', () {
    // openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | sha256 | base64
    expect(CertificatePinning.spkiSha256(_der(leafPem)),
        'mZJhbNfh0XL13JCduBWxMJ4+cemBCsVEPRXHXmScEeE=');
  });

  test('the leaf pin is the first entry of the const pin list', () {
    expect(CertificatePinning.spkiPins.first, CertificatePinning.spkiSha256(_der(leafPem)));
    expect(CertificatePinning.spkiPins, hasLength(3));
  });

  test('root SPKI pin matches the embedded Amazon Root CA 1', () {
    final roots = CertificatePinning.pinnedCaBundlePem.split('-----END CERTIFICATE-----');
    final first = '${roots.first}-----END CERTIFICATE-----';
    expect(CertificatePinning.spkiSha256(_der(first)), CertificatePinning.spkiPins.last);
  });

  test('garbage DER yields no pin rather than throwing', () {
    expect(CertificatePinning.spkiSha256(Uint8List.fromList([0x30, 0x82, 0xff])), isNull);
    expect(CertificatePinning.spkiSha256(Uint8List(0)), isNull);
    expect(CertificatePinning.subjectPublicKeyInfo(Uint8List.fromList([0x04, 0x01, 0x00])), isNull);
  });

  test('only api.doqto.ai is pinned', () {
    expect(CertificatePinning.appliesTo('https://api.doqto.ai'), isTrue);
    expect(CertificatePinning.appliesTo('http://localhost:8010'), isFalse);
    expect(CertificatePinning.appliesTo('wss://api.doqto.ai'), isTrue);
    // Debug/test builds never enforce, even for the production host.
    expect(CertificatePinning.enforces('https://api.doqto.ai'), isFalse);
    expect(CertificatePinning.securityContext('https://api.doqto.ai'), isNull);
  });

  test('the pinned trust store builds from the embedded bundle', () {
    expect(CertificatePinning.buildPinnedContext(), isA<SecurityContext>());
    expect(
      RegExp('BEGIN CERTIFICATE').allMatches(CertificatePinning.pinnedCaBundlePem).length,
      5,
    );
  });

  test('a missing or foreign leaf fails the match; other hosts always pass', () {
    expect(CertificatePinning.leafMatches(null), isFalse);
    expect(CertificatePinning.validateLeaf(null, 'api.doqto.ai', 443), isTrue,
        reason: 'leaf pin is log-only until enforceLeafPin flips');
    expect(CertificatePinning.enforceLeafPin, isFalse);
    expect(CertificatePinning.validateLeaf(null, 'localhost', 8010), isTrue);
  });

  test('an HttpClient builds for the pinned and the local host', () {
    for (final base in ['https://api.doqto.ai', 'http://localhost:8010']) {
      final client = CertificatePinning.httpClient(base);
      addTearDown(client.close);
      expect(client, isA<HttpClient>());
    }
  });
}
