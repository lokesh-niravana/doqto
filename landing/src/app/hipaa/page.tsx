import type { Metadata } from "next";
import Navbar from "@/components/layout/Navbar";
import Footer from "@/components/layout/Footer";

export const metadata: Metadata = {
  title: "HIPAA Compliance | Doqto",
  description:
    "How Doqto protects Protected Health Information: encryption, access controls, audit trails, Business Associate Agreements and what is still in progress.",
};

// Every statement on this page is checked against docs/security.md and
// compliance/README.md. Say what is in place today; label what is in
// progress. Never add a control here before it exists.
export default function HIPAAPage() {
  return (
    <>
      <Navbar />
      <main className="bg-cream min-h-screen pt-24 pb-16">
        <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8">
          <h1 className="text-4xl sm:text-5xl font-bold text-ink mb-4">
            HIPAA Compliance
          </h1>
          <p className="text-ink-soft mb-12">Last updated: November 2026</p>

          {/* 1 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">1.</span>Our Role and
              Commitment
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              Doqto is secure messaging for clinicians. When a practice or
              hospital uses Doqto to discuss patient care, DOQTO LLC acts as a
              Business Associate under HIPAA and is responsible for safeguarding
              the Protected Health Information (PHI) that passes through the
              service. The platform is built around the HIPAA Privacy Rule,
              Security Rule and Breach Notification Rule.
            </p>
            <p className="text-ink-soft leading-relaxed">
              This page describes the safeguards that are in place today and,
              in plain terms, the parts of our compliance programme that are
              still being completed. We would rather tell you what is in
              progress than overstate it.
            </p>
          </section>

          {/* 2 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">2.</span>Technical Safeguards
            </h2>
            <ul className="list-disc list-inside text-ink-soft space-y-3 ml-4">
              <li>
                <span className="text-ink">Encryption at rest:</span> message
                text, captions, voice-note transcripts, polls and drafts are
                encrypted with AES-256-GCM before they are written to the
                database, using a separate data key for every organisation
                (envelope encryption). Keys can be rotated without downtime.
                Databases, caches and file storage are additionally encrypted
                at the storage layer.
              </li>
              <li>
                <span className="text-ink">Encryption in transit:</span> TLS 1.2
                or newer for every connection, with certificate pinning in the
                mobile apps.
              </li>
              <li>
                <span className="text-ink">Access controls:</span> every user is
                individually identified; sign-in is verified by phone, Apple or
                Google identity; the app can be locked behind the device&apos;s
                biometrics; sessions can be reviewed and signed out remotely,
                and a lost device can be wiped from another one.
              </li>
              <li>
                <span className="text-ink">Audit controls:</span> sign-ins,
                reads, administrative actions and key rotations are written to
                a tamper-evident audit log in which each entry is
                cryptographically chained to the one before it. Audit records
                are retained for at least six years.
              </li>
              <li>
                <span className="text-ink">Minimum necessary by design:</span>{" "}
                push notifications never contain message content; voice-note
                transcription runs on the phone itself, never on a third-party
                speech service; the apps contain no analytics or
                crash-reporting SDKs; screenshots are blocked where the device
                allows it and otherwise detected and audited.
              </li>
              <li>
                <span className="text-ink">Retention and deletion:</span>{" "}
                organisations can set message retention periods and legal
                holds; users can delete their account, after which their
                content is shredded and only the audit trail remains.
              </li>
              <li>
                <span className="text-ink">Administrative access to PHI:</span>{" "}
                Doqto staff cannot read conversations in normal operation.
                Emergency (&quot;break-glass&quot;) access requires a recorded
                justification and is itself audited.
              </li>
            </ul>
          </section>

          {/* 3 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">3.</span>Physical Safeguards
            </h2>
            <ul className="list-disc list-inside text-ink-soft space-y-3 ml-4">
              <li>
                <span className="text-ink">Hosting:</span> all PHI is processed
                and stored in Amazon Web Services (US East), under a Business
                Associate Addendum with AWS and using only AWS services that
                are eligible for HIPAA workloads. AWS maintains the physical
                security, SOC and ISO certifications of its data centres.
              </li>
              <li>
                <span className="text-ink">Workstations:</span> PHI is never
                stored on Doqto company devices; the service is designed so
                that staff do not need to see message content to operate it.
              </li>
            </ul>
          </section>

          {/* 4 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">4.</span>Administrative
              Safeguards
            </h2>
            <ul className="list-disc list-inside text-ink-soft space-y-3 ml-4">
              <li>
                <span className="text-ink">Role-based access:</span>{" "}
                organisation administrators control membership, retention and
                access requests for their own organisation only.
              </li>
              <li>
                <span className="text-ink">Workforce:</span> everyone who works
                on Doqto is bound by confidentiality obligations.
              </li>
              <li>
                <span className="text-ink">In progress:</span> formal
                designation of our Security and Privacy Officers, a documented
                risk analysis, a published policy set and recorded HIPAA
                training for every team member are being completed now. We
                will update this page as each is finished, and customers can
                ask us for the current status at any time.
              </li>
            </ul>
          </section>

          {/* 5 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">5.</span>Business Associate
              Agreements
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              DOQTO LLC signs a Business Associate Agreement with every Covered
              Entity before PHI is exchanged through the service. Our standard
              terms are on the{" "}
              <a href="/baa" className="text-primary hover:underline">
                BAA page
              </a>
              .
            </p>
            <p className="text-ink-soft leading-relaxed mb-4">
              We hold agreements with the subcontractors that touch PHI on our
              behalf:
            </p>
            <ul className="list-disc list-inside text-ink-soft space-y-3 ml-4">
              <li>
                <span className="text-ink">Amazon Web Services:</span> hosting,
                databases, storage and key management (AWS Business Associate
                Addendum).
              </li>
              <li>
                <span className="text-ink">Google Cloud:</span> sign-in identity
                only; no message content (Google Cloud HIPAA Business Associate
                Addendum).
              </li>
            </ul>
            <p className="text-ink-soft leading-relaxed mt-4">
              Push delivery through Apple and Google carries no PHI, so no
              agreement is needed with those services.
            </p>
          </section>

          {/* 6 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">6.</span>Breach Notification
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              In the event of a breach of unsecured PHI, Doqto will:
            </p>
            <ul className="list-decimal list-inside text-ink-soft space-y-3 ml-4">
              <li>Investigate and contain the incident on discovery</li>
              <li>
                Notify affected Covered Entities without unreasonable delay and
                no later than sixty (60) days after discovery
              </li>
              <li>
                Provide the information required under 45 CFR § 164.410: the
                nature of the breach, the PHI involved and the steps taken to
                mitigate harm
              </li>
              <li>
                Cooperate with Covered Entities in their notifications to
                affected individuals and to the HHS Secretary
              </li>
              <li>
                Record the incident, the investigation and the corrective
                actions, and keep that record for at least six (6) years
              </li>
            </ul>
          </section>

          {/* 7 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">7.</span>Backup and Recovery
            </h2>
            <ul className="list-disc list-inside text-ink-soft space-y-3 ml-4">
              <li>
                Automated, encrypted database backups with point-in-time
                recovery over the previous seven days
              </li>
              <li>
                Encrypted file storage with versioning, independent of the
                application servers
              </li>
              <li>
                Infrastructure defined as code, so the environment can be
                rebuilt from source
              </li>
            </ul>
          </section>

          {/* 8 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">8.</span>Testing and
              Independent Review
            </h2>
            <ul className="list-disc list-inside text-ink-soft space-y-3 ml-4">
              <li>
                Automated tests cover the security controls above (encryption,
                audit chaining, retention, key rotation, keyboard and screen
                privacy in the apps) and run on every change
              </li>
              <li>Dependencies are kept current and reviewed for advisories</li>
              <li>
                <span className="text-ink">Planned:</span> an independent
                penetration test before our first hospital deployment. We do not
                currently hold a SOC 2 or HITRUST certification and will not
                claim one until we do.
              </li>
            </ul>
          </section>

          {/* 9 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">9.</span>Contact
            </h2>
            <p className="text-ink-soft leading-relaxed">
              Questions about our HIPAA posture, requests for our BAA, or a
              security concern to report:
            </p>
            <div className="mt-4 text-ink-soft">
              <p className="text-ink font-medium">DOQTO LLC</p>
              <p>
                Compliance:{" "}
                <a
                  href="mailto:compliance@doqto.ai"
                  className="text-primary hover:underline"
                >
                  compliance@doqto.ai
                </a>
              </p>
              <p>
                Security:{" "}
                <a
                  href="mailto:security@doqto.ai"
                  className="text-primary hover:underline"
                >
                  security@doqto.ai
                </a>
              </p>
              <p>
                General:{" "}
                <a
                  href="mailto:hello@doqto.ai"
                  className="text-primary hover:underline"
                >
                  hello@doqto.ai
                </a>
              </p>
            </div>
          </section>
        </div>
      </main>
      <Footer />
    </>
  );
}
