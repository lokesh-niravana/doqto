# Compliance

Registers and policies that make the HIPAA posture described in
`docs/security.md` demonstrable. Add a row to the register for every
agreement signed.

Executed agreement copies live in `agreements/`, which is **git-ignored**:
the AWS BAA text is confidential under the AWS Artifact NDA and must not be
pushed or shared outside DOQTO LLC. Keep the originals in the founders'
shared drive as well.

## Business Associate Agreements register

| Party | Role | Agreement | Status | Effective | Accepted by | Account / scope |
|---|---|---|---|---|---|---|
| Amazon Web Services | Subcontractor: hosts all PHI (RDS Postgres, ElastiCache Redis, S3, ECS, ALB, CloudWatch, KMS) | AWS Business Associate Addendum (AWS Artifact, account agreement) | **Active** | 2026-11-25 | Lokesh Tamiri, AWS console | AWS account 943014910992 "Doqto AI". Obligations: HIPAA Eligible Services only, PHI encrypted in transit and at rest; AWS service teams opted out of using customer content. Local copy: `agreements/2026-11-25-aws-business-associate-addendum.pdf` |
| Google Cloud (Firebase Identity Platform) | Subcontractor: sign-in identity (phone, email); no PHI | Google Cloud Business Associate Agreement | **Active** | 2026-09-22 | lokesh@doqto.ai, Cloud console (IAM & Admin, Privacy & Security) | Project doqto-90684. Covers Identity Platform. Firebase Cloud Messaging is not a covered service: pushes carry no PHI by design (`app/services/push_service.py`). Google issues no per-customer signed copy: the acceptance record is the console line "Reviewed and accepted on 22 Sept 2026 by lokesh@doqto.ai" (IAM & Admin, Privacy & Security). Local copies: `agreements/2026-09-22-google-cloud-hipaa-baa-acceptance-record.jpg` and the terms as `agreements/2026-09-22-google-cloud-hipaa-baa-terms.pdf` |
| Apple (APNs, Sign in with Apple) | Push delivery, identity | None available: Apple does not sign BAAs | n/a | | | Pushes are PHI-free by design |
| Stripe | Billing: email and user id only | Not required (no PHI) | n/a | | | Removed from 1.0; see `docs/payments.md` |
| CMS NPPES registry | Public NPI lookup, outbound only | Not required (public data) | n/a | | | |
| MongoDB Atlas | Landing-page waitlist emails | Not required (no PHI) | n/a | | | |
| Customer organizations (practices, hospitals) | Covered Entities; DOQTO LLC is their Business Associate | Doqto customer BAA | **Not started** | | | Template at doqto.ai/baa names "Doqto, Inc." and needs the entity corrected to DOQTO LLC plus attorney review; no signing flow yet |

## Done

- 2026-11-26: on-device-only voice transcription enforced in the app (build
  47, `docs/security.md` "Voice transcripts never leave the phone").
- 2026-11-26: legal pages name DOQTO LLC; the HIPAA page states only the
  controls that exist and labels the rest "in progress".

- 2026-11-25: message data keys wrapped by AWS KMS in production
  (`alias/doqto-backend-messages`, key 0a5b03bf-8f34-41be-bced-21b590628117,
  yearly rotation). All scopes rotated, 142 rows rewrapped, 0 rows left on
  the legacy static key. Postgres connection now `ssl=require`, verified
  TLS 1.2. The static `MESSAGE_ENCRYPTION_KEY` remains only to unwrap the
  retired network key v1 and to protect the transient WebSocket envelope.

## Open items

- Customer BAA: attorney review, entity fix, click-to-accept at
  organization creation with the acceptance recorded in the audit log.
- Policy set, risk analysis, officer designations, workforce training
  records: see the compliance plan of 2026-11-25.
