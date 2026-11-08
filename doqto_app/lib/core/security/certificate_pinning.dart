import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Certificate pinning for the production API (batch 7, docs/security.md).
///
/// What Dart's `HttpClient` can and cannot do shaped this:
///
/// * `badCertificateCallback` fires only for a chain the trust store already
///   rejected — it can never veto a chain that validated, so it is not a pin.
/// * After the handshake the only certificate exposed is the **leaf**
///   (`HttpClientResponse.certificate`, which dio hands to
///   `IOHttpClientAdapter.validateCertificate`). The intermediate is never
///   reachable from Dart, so an intermediate SPKI pin cannot be checked
///   post-handshake.
///
/// So pinning is done in two layers:
///
/// 1. **CA pinning (fail closed in release).** [securityContext] trusts only
///    the Amazon Trust Services roots the api.doqto.ai chain anchors to
///    (`Amazon RSA 2048 M01` → `Amazon Root CA 1`, plus the sibling Amazon
///    roots and the Starfield G2 cross-sign root). A corporate proxy, a
///    rogue CA or a user-installed root cannot complete a handshake. The
///    pinned set survives ACM's leaf and intermediate rotations.
/// 2. **Leaf SPKI check (post-handshake).** [validateLeaf] parses the leaf's
///    SubjectPublicKeyInfo out of its DER and compares its SHA-256 with
///    [spkiPins]. A mismatch is logged everywhere; it only refuses the
///    connection when [enforceLeafPin] is true. ACM renews api.doqto.ai with
///    a **new key pair** (next renewal before 2027-02-23), which would brick
///    every installed build with a hard leaf pin — so the flag ships off
///    until the certificate moves to a key we control. Flip it after that.
///
/// Debug builds never refuse: both layers log only, so a local proxy for
/// debugging keeps working. Hosts other than [pinnedHost] are untouched.
class CertificatePinning {
  CertificatePinning._();

  /// The only host pinned. Local/staging bases are not.
  static const String pinnedHost = 'api.doqto.ai';

  /// SHA-256 of the DER SubjectPublicKeyInfo, base64 (the HPKP / OkHttp
  /// `sha256/` form), computed from the live chain on 2026-11-08:
  ///
  ///     openssl s_client -connect api.doqto.ai:443 -showcerts
  ///     openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
  ///       | openssl dgst -sha256 -binary | base64
  static const List<String> spkiPins = [
    // Leaf: CN=api.doqto.ai, valid 2026-08-10 → 2027-02-23.
    'mZJhbNfh0XL13JCduBWxMJ4+cemBCsVEPRXHXmScEeE=',
    // Issuing intermediate: Amazon RSA 2048 M01 (→ 2030-08-23).
    'DxH4tt40L+eduF6szpY6TONlxhZhBd+pJ9wbHlQ2fuw=',
    // Root: Amazon Root CA 1 (→ 2038-01-17); same key in the cross-signed copy.
    '++MBgDH5WGvL9Bcn5Be30cRcL0f5O+NyoXuWtQdX1aI=',
  ];

  /// Refuse a leaf whose SPKI is not in [spkiPins] (release only). Off: see
  /// the class comment.
  static const bool enforceLeafPin = false;

  /// Whether the given API base URL is the pinned production host.
  static bool appliesTo(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    return uri != null && uri.host == pinnedHost;
  }

  /// Fail closed only in release and only for the pinned host.
  static bool enforces(String baseUrl) => kReleaseMode && appliesTo(baseUrl);

  static SecurityContext? _pinnedContext;

  /// A trust store holding nothing but the pinned CA chain. Null when
  /// [baseUrl] is not the pinned host or this is not a release build (the
  /// platform roots stay in charge, so debugging proxies keep working).
  static SecurityContext? securityContext(String baseUrl) {
    if (!enforces(baseUrl)) return null;
    return _pinnedContext ??= buildPinnedContext();
  }

  /// The pinned trust store itself, regardless of build mode (tests).
  static SecurityContext buildPinnedContext() {
    final ctx = SecurityContext(withTrustedRoots: false);
    ctx.setTrustedCertificatesBytes(utf8.encode(pinnedCaBundlePem));
    return ctx;
  }

  /// `HttpClient` for [baseUrl]: pinned trust store in release for the
  /// production host, and a bad-certificate callback that never accepts.
  static HttpClient httpClient(String baseUrl) {
    final client = HttpClient(context: securityContext(baseUrl));
    client.badCertificateCallback = (cert, host, port) {
      debugPrint('tls: rejected certificate for $host:$port (${cert.subject})');
      return false;
    };
    return client;
  }

  /// Post-handshake leaf check for dio's `validateCertificate`. Returns
  /// whether the response may be used.
  static bool validateLeaf(X509Certificate? cert, String host, int port) {
    if (host != pinnedHost) return true;
    final verdict = leafMatches(cert);
    if (verdict) return true;
    debugPrint('tls: leaf SPKI for $host:$port is not in the pin list');
    return !(kReleaseMode && enforceLeafPin);
  }

  /// Whether [cert]'s SPKI SHA-256 is one of [spkiPins].
  static bool leafMatches(X509Certificate? cert) {
    if (cert == null) return false;
    final pin = spkiSha256(cert.der);
    return pin != null && spkiPins.contains(pin);
  }

  /// Base64 SHA-256 of the SubjectPublicKeyInfo inside a DER certificate,
  /// or null when the DER does not parse.
  static String? spkiSha256(Uint8List der) {
    final spki = subjectPublicKeyInfo(der);
    if (spki == null) return null;
    return base64.encode(sha256.convert(spki).bytes);
  }

  /// The raw SubjectPublicKeyInfo TLV of an X.509 DER certificate.
  ///
  ///     Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
  ///     TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber,
  ///        signature, issuer, validity, subject, subjectPublicKeyInfo, ... }
  @visibleForTesting
  static Uint8List? subjectPublicKeyInfo(Uint8List der) {
    try {
      final cert = _Tlv.read(der, 0);
      if (cert.tag != 0x30) return null;
      final tbs = _Tlv.read(der, cert.contentStart);
      if (tbs.tag != 0x30) return null;
      var pos = tbs.contentStart;
      var field = 0; // 0 serial, 1 signature, 2 issuer, 3 validity, 4 subject, 5 spki
      while (pos < tbs.end) {
        final t = _Tlv.read(der, pos);
        if (t.tag == 0xA0 && field == 0 && pos == tbs.contentStart) {
          pos = t.end; // explicit version
          continue;
        }
        if (field == 5) {
          return t.tag == 0x30 ? Uint8List.sublistView(der, t.start, t.end) : null;
        }
        field++;
        pos = t.end;
      }
    } catch (_) {}
    return null;
  }

  /// PEM bundle the pinned [SecurityContext] trusts: the five Amazon Trust
  /// Services roots, from https://www.amazontrust.com/repository/.
  static const String pinnedCaBundlePem = r"""
-----BEGIN CERTIFICATE-----
MIIDQTCCAimgAwIBAgITBmyfz5m/jAo54vB4ikPmljZbyjANBgkqhkiG9w0BAQsF
ADA5MQswCQYDVQQGEwJVUzEPMA0GA1UEChMGQW1hem9uMRkwFwYDVQQDExBBbWF6
b24gUm9vdCBDQSAxMB4XDTE1MDUyNjAwMDAwMFoXDTM4MDExNzAwMDAwMFowOTEL
MAkGA1UEBhMCVVMxDzANBgNVBAoTBkFtYXpvbjEZMBcGA1UEAxMQQW1hem9uIFJv
b3QgQ0EgMTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALJ4gHHKeNXj
ca9HgFB0fW7Y14h29Jlo91ghYPl0hAEvrAIthtOgQ3pOsqTQNroBvo3bSMgHFzZM
9O6II8c+6zf1tRn4SWiw3te5djgdYZ6k/oI2peVKVuRF4fn9tBb6dNqcmzU5L/qw
IFAGbHrQgLKm+a/sRxmPUDgH3KKHOVj4utWp+UhnMJbulHheb4mjUcAwhmahRWa6
VOujw5H5SNz/0egwLX0tdHA114gk957EWW67c4cX8jJGKLhD+rcdqsq08p8kDi1L
93FcXmn/6pUCyziKrlA4b9v7LWIbxcceVOF34GfID5yHI9Y/QCB/IIDEgEw+OyQm
jgSubJrIqg0CAwEAAaNCMEAwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMC
AYYwHQYDVR0OBBYEFIQYzIU07LwMlJQuCFmcx7IQTgoIMA0GCSqGSIb3DQEBCwUA
A4IBAQCY8jdaQZChGsV2USggNiMOruYou6r4lK5IpDB/G/wkjUu0yKGX9rbxenDI
U5PMCCjjmCXPI6T53iHTfIUJrU6adTrCC2qJeHZERxhlbI1Bjjt/msv0tadQ1wUs
N+gDS63pYaACbvXy8MWy7Vu33PqUXHeeE6V/Uq2V8viTO96LXFvKWlJbYK8U90vv
o/ufQJVtMVT8QtPHRh8jrdkPSHCa2XV4cdFyQzR1bldZwgJcJmApzyMZFo6IQ6XU
5MsI+yMRQ+hDKXJioaldXgjUkK642M4UwtBV8ob2xJNDd2ZhwLnoQdeXeGADbkpy
rqXRfboQnoZsG4q5WTP468SQvvG5
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIFQTCCAymgAwIBAgITBmyf0pY1hp8KD+WGePhbJruKNzANBgkqhkiG9w0BAQwF
ADA5MQswCQYDVQQGEwJVUzEPMA0GA1UEChMGQW1hem9uMRkwFwYDVQQDExBBbWF6
b24gUm9vdCBDQSAyMB4XDTE1MDUyNjAwMDAwMFoXDTQwMDUyNjAwMDAwMFowOTEL
MAkGA1UEBhMCVVMxDzANBgNVBAoTBkFtYXpvbjEZMBcGA1UEAxMQQW1hem9uIFJv
b3QgQ0EgMjCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK2Wny2cSkxK
gXlRmeyKy2tgURO8TW0G/LAIjd0ZEGrHJgw12MBvIITplLGbhQPDW9tK6Mj4kHbZ
W0/jTOgGNk3Mmqw9DJArktQGGWCsN0R5hYGCrVo34A3MnaZMUnbqQ523BNFQ9lXg
1dKmSYXpN+nKfq5clU1Imj+uIFptiJXZNLhSGkOQsL9sBbm2eLfq0OQ6PBJTYv9K
8nu+NQWpEjTj82R0Yiw9AElaKP4yRLuH3WUnAnE72kr3H9rN9yFVkE8P7K6C4Z9r
2UXTu/Bfh+08LDmG2j/e7HJV63mjrdvdfLC6HM783k81ds8P+HgfajZRRidhW+me
z/CiVX18JYpvL7TFz4QuK/0NURBs+18bvBt+xa47mAExkv8LV/SasrlX6avvDXbR
8O70zoan4G7ptGmh32n2M8ZpLpcTnqWHsFcQgTfJU7O7f/aS0ZzQGPSSbtqDT6Zj
mUyl+17vIWR6IF9sZIUVyzfpYgwLKhbcAS4y2j5L9Z469hdAlO+ekQiG+r5jqFoz
7Mt0Q5X5bGlSNscpb/xVA1wf+5+9R+vnSUeVC06JIglJ4PVhHvG/LopyboBZ/1c6
+XUyo05f7O0oYtlNc/LMgRdg7c3r3NunysV+Ar3yVAhU/bQtCSwXVEqY0VThUWcI
0u1ufm8/0i2BWSlmy5A5lREedCf+3euvAgMBAAGjQjBAMA8GA1UdEwEB/wQFMAMB
Af8wDgYDVR0PAQH/BAQDAgGGMB0GA1UdDgQWBBSwDPBMMPQFWAJI/TPlUq9LhONm
UjANBgkqhkiG9w0BAQwFAAOCAgEAqqiAjw54o+Ci1M3m9Zh6O+oAA7CXDpO8Wqj2
LIxyh6mx/H9z/WNxeKWHWc8w4Q0QshNabYL1auaAn6AFC2jkR2vHat+2/XcycuUY
+gn0oJMsXdKMdYV2ZZAMA3m3MSNjrXiDCYZohMr/+c8mmpJ5581LxedhpxfL86kS
k5Nrp+gvU5LEYFiwzAJRGFuFjWJZY7attN6a+yb3ACfAXVU3dJnJUH/jWS5E4ywl
7uxMMne0nxrpS10gxdr9HIcWxkPo1LsmmkVwXqkLN1PiRnsn/eBG8om3zEK2yygm
btmlyTrIQRNg91CMFa6ybRoVGld45pIq2WWQgj9sAq+uEjonljYE1x2igGOpm/Hl
urR8FLBOybEfdF849lHqm/osohHUqS0nGkWxr7JOcQ3AWEbWaQbLU8uz/mtBzUF+
fUwPfHJ5elnNXkoOrJupmHN5fLT0zLm4BwyydFy4x2+IoZCn9Kr5v2c69BoVYh63
n749sSmvZ6ES8lgQGVMDMBu4Gon2nL2XA46jCfMdiyHxtN/kHNGfZQIG6lzWE7OE
76KlXIx3KadowGuuQNKotOrN8I1LOJwZmhsoVLiJkO/KdYE+HvJkJMcYr07/R54H
9jVlpNMKVv/1F2Rs76giJUmTtt8AF9pYfl3uxRuw0dFfIRDH+fO6AgonB8Xx1sfT
4PsJYGw=
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIBtjCCAVugAwIBAgITBmyf1XSXNmY/Owua2eiedgPySjAKBggqhkjOPQQDAjA5
MQswCQYDVQQGEwJVUzEPMA0GA1UEChMGQW1hem9uMRkwFwYDVQQDExBBbWF6b24g
Um9vdCBDQSAzMB4XDTE1MDUyNjAwMDAwMFoXDTQwMDUyNjAwMDAwMFowOTELMAkG
A1UEBhMCVVMxDzANBgNVBAoTBkFtYXpvbjEZMBcGA1UEAxMQQW1hem9uIFJvb3Qg
Q0EgMzBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABCmXp8ZBf8ANm+gBG1bG8lKl
ui2yEujSLtf6ycXYqm0fc4E7O5hrOXwzpcVOho6AF2hiRVd9RFgdszflZwjrZt6j
QjBAMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgGGMB0GA1UdDgQWBBSr
ttvXBp43rDCGB5Fwx5zEGbF4wDAKBggqhkjOPQQDAgNJADBGAiEA4IWSoxe3jfkr
BqWTrBqYaGFy+uGh0PsceGCmQ5nFuMQCIQCcAu/xlJyzlvnrxir4tiz+OpAUFteM
YyRIHN8wfdVoOw==
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIB8jCCAXigAwIBAgITBmyf18G7EEwpQ+Vxe3ssyBrBDjAKBggqhkjOPQQDAzA5
MQswCQYDVQQGEwJVUzEPMA0GA1UEChMGQW1hem9uMRkwFwYDVQQDExBBbWF6b24g
Um9vdCBDQSA0MB4XDTE1MDUyNjAwMDAwMFoXDTQwMDUyNjAwMDAwMFowOTELMAkG
A1UEBhMCVVMxDzANBgNVBAoTBkFtYXpvbjEZMBcGA1UEAxMQQW1hem9uIFJvb3Qg
Q0EgNDB2MBAGByqGSM49AgEGBSuBBAAiA2IABNKrijdPo1MN/sGKe0uoe0ZLY7Bi
9i0b2whxIdIA6GO9mif78DluXeo9pcmBqqNbIJhFXRbb/egQbeOc4OO9X4Ri83Bk
M6DLJC9wuoihKqB1+IGuYgbEgds5bimwHvouXKNCMEAwDwYDVR0TAQH/BAUwAwEB
/zAOBgNVHQ8BAf8EBAMCAYYwHQYDVR0OBBYEFNPsxzplbszh2naaVvuc84ZtV+WB
MAoGCCqGSM49BAMDA2gAMGUCMDqLIfG9fhGt0O9Yli/W651+kI0rz2ZVwyzjKKlw
CkcO8DdZEv8tmZQoTipPNU0zWgIxAOp1AE47xDqUEpHJWEadIRNyp4iciuRMStuW
1KyLa2tJElMzrdfkviT8tQp21KW8EA==
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIID7zCCAtegAwIBAgIBADANBgkqhkiG9w0BAQsFADCBmDELMAkGA1UEBhMCVVMx
EDAOBgNVBAgTB0FyaXpvbmExEzARBgNVBAcTClNjb3R0c2RhbGUxJTAjBgNVBAoT
HFN0YXJmaWVsZCBUZWNobm9sb2dpZXMsIEluYy4xOzA5BgNVBAMTMlN0YXJmaWVs
ZCBTZXJ2aWNlcyBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAtIEcyMB4XDTA5
MDkwMTAwMDAwMFoXDTM3MTIzMTIzNTk1OVowgZgxCzAJBgNVBAYTAlVTMRAwDgYD
VQQIEwdBcml6b25hMRMwEQYDVQQHEwpTY290dHNkYWxlMSUwIwYDVQQKExxTdGFy
ZmllbGQgVGVjaG5vbG9naWVzLCBJbmMuMTswOQYDVQQDEzJTdGFyZmllbGQgU2Vy
dmljZXMgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgLSBHMjCCASIwDQYJKoZI
hvcNAQEBBQADggEPADCCAQoCggEBANUMOsQq+U7i9b4Zl1+OiFOxHz/Lz58gE20p
OsgPfTz3a3Y4Y9k2YKibXlwAgLIvWX/2h/klQ4bnaRtSmpDhcePYLQ1Ob/bISdm2
8xpWriu2dBTrz/sm4xq6HZYuajtYlIlHVv8loJNwU4PahHQUw2eeBGg6345AWh1K
Ts9DkTvnVtYAcMtS7nt9rjrnvDH5RfbCYM8TWQIrgMw0R9+53pBlbQLPLJGmpufe
hRhJfGZOozptqbXuNC66DQO4M99H67FrjSXZm86B0UVGMpZwh94CDklDhbZsc7tk
6mFBrMnUVN+HL8cisibMn1lUaJ/8viovxFUcdUBgF4UCVTmLfwUCAwEAAaNCMEAw
DwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYEFJxfAN+q
AdcwKziIorhtSpzyEZGDMA0GCSqGSIb3DQEBCwUAA4IBAQBLNqaEd2ndOxmfZyMI
bw5hyf2E3F/YNoHN2BtBLZ9g3ccaaNnRbobhiCPPE95Dz+I0swSdHynVv/heyNXB
ve6SbzJ08pGCL72CQnqtKrcgfU28elUSwhXqvfdqlS5sdJ/PHLTyxQGjhdByPq1z
qwubdQxtRbeOlKyWN7Wg0I8VRw7j6IPdj/3vQQF3zCepYoUz8jcI73HPdwbeyBkd
iEDPfUYd/x7H4c7/I9vG+o1VTqkC50cRRj70/b17KSa7qWFiNyi2LSr2EIZkyXCn
0q23KXB56jzaYyWf/Wi3MOxw+3WKt21gZ7IeyLnp2KhvAotnDU0mV3HaIPzBSlCN
sSi6
-----END CERTIFICATE-----
""";
}

/// One DER tag-length-value element.
class _Tlv {
  final int tag;
  final int start;
  final int contentStart;
  final int end;
  const _Tlv(this.tag, this.start, this.contentStart, this.end);

  static _Tlv read(Uint8List b, int start) {
    final tag = b[start];
    var i = start + 1;
    var len = b[i++];
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      if (n == 0 || n > 4) throw const FormatException('bad DER length');
      len = 0;
      for (var k = 0; k < n; k++) {
        len = (len << 8) | b[i++];
      }
    }
    final end = i + len;
    if (end > b.length) throw const FormatException('DER overrun');
    return _Tlv(tag, start, i, end);
  }
}
