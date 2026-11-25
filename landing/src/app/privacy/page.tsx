import type { Metadata } from "next";
import Navbar from "@/components/layout/Navbar";
import Footer from "@/components/layout/Footer";

export const metadata: Metadata = {
  title: "Privacy Policy | Doqto",
  description:
    "Privacy Policy for Doqto — learn how we protect your data with HIPAA-compliant practices, E2E encryption, and strict data handling policies.",
};

export default function PrivacyPage() {
  return (
    <>
      <Navbar />
      <main className="bg-cream min-h-screen pt-24 pb-16">
        <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8">
          <h1 className="text-4xl sm:text-5xl font-bold text-ink mb-4">
            Privacy Policy
          </h1>
          <p className="text-ink-soft mb-12">Last updated: November 2026</p>

          {/* 1 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">1.</span>Introduction
            </h2>
            <p className="text-ink-soft leading-relaxed">
              DOQTO LLC (&quot;Company,&quot; &quot;we,&quot; &quot;us,&quot;
              or &quot;our&quot;) is committed to protecting the privacy and
              security of your personal information and any Protected Health
              Information (PHI) processed through our platform. This Privacy
              Policy explains how we collect, use, disclose, and safeguard your
              information when you use the Doqto platform (&quot;Service&quot;).
              By using our Service, you consent to the practices described in
              this policy.
            </p>
          </section>

          {/* 2 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">2.</span>Information We
              Collect
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              We collect the following categories of information:
            </p>

            <h3 className="text-ink font-medium mb-2 mt-6">
              Account Information
            </h3>
            <ul className="list-disc list-inside text-ink-soft space-y-2 ml-4">
              <li>Name, phone number, and professional credentials</li>
              <li>Organization and department affiliations</li>
              <li>Profile information you choose to provide</li>
            </ul>

            <h3 className="text-ink font-medium mb-2 mt-6">Usage Data</h3>
            <ul className="list-disc list-inside text-ink-soft space-y-2 ml-4">
              <li>
                Device information (type, operating system, app version)
              </li>
              <li>Log data (access times, pages viewed, IP address)</li>
              <li>Feature usage analytics (aggregated and anonymized)</li>
            </ul>

            <h3 className="text-ink font-medium mb-2 mt-6">
              Health-Related Communications Metadata
            </h3>
            <ul className="list-disc list-inside text-ink-soft space-y-2 ml-4">
              <li>
                Message timestamps and delivery status (not message content —
                content is end-to-end encrypted)
              </li>
              <li>Participant identifiers for message routing</li>
              <li>File transfer metadata (file size, type, timestamp)</li>
            </ul>
          </section>

          {/* 3 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">3.</span>How We Use Your
              Information
            </h2>
            <ul className="list-disc list-inside text-ink-soft space-y-2 ml-4">
              <li>To provide, maintain, and improve the Service</li>
              <li>To authenticate your identity and manage your account</li>
              <li>
                To facilitate secure communications between healthcare
                professionals
              </li>
              <li>
                To send service-related notifications and security alerts
              </li>
              <li>To comply with legal and regulatory obligations</li>
              <li>
                To detect, prevent, and respond to security incidents and fraud
              </li>
              <li>
                To generate aggregated, de-identified analytics to improve our
                Service
              </li>
            </ul>
          </section>

          {/* 4 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">4.</span>HIPAA Compliance &
              Protected Health Information
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              We recognize that communications through our Service may contain
              Protected Health Information (PHI) as defined by HIPAA. We handle
              PHI in strict accordance with HIPAA regulations:
            </p>
            <ul className="list-disc list-inside text-ink-soft space-y-2 ml-4">
              <li>
                We enter into Business Associate Agreements (BAAs) with all
                Covered Entities
              </li>
              <li>
                PHI is protected by end-to-end encryption — we cannot access
                message content
              </li>
              <li>
                We implement administrative, physical, and technical safeguards
                as required by the HIPAA Security Rule
              </li>
              <li>
                We limit the use and disclosure of PHI to the minimum necessary
                to provide the Service
              </li>
              <li>
                We maintain comprehensive audit logs of all system access and
                activity
              </li>
            </ul>
          </section>

          {/* 5 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">5.</span>End-to-End Encryption
            </h2>
            <p className="text-ink-soft leading-relaxed">
              All messages and file transfers on Doqto are protected with
              AES-256 end-to-end encryption. This means that only the sender and
              intended recipients can read message content. Doqto servers
              cannot decrypt your messages. Encryption keys are generated and
              managed on your device and are never transmitted to or stored on
              our servers. Even in the event of a server breach, your message
              content remains unreadable to any unauthorized party, including
              Doqto.
            </p>
          </section>

          {/* 6 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">6.</span>Data Sharing & Third
              Parties
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              We do not sell your personal information or PHI. We may share
              information with:
            </p>
            <ul className="list-disc list-inside text-ink-soft space-y-2 ml-4">
              <li>
                <span className="text-ink">Service providers:</span>{" "}
                Third-party vendors who assist in operating our Service (cloud
                hosting, analytics), bound by BAAs and strict confidentiality
                agreements
              </li>
              <li>
                <span className="text-ink">Legal requirements:</span> When
                required by law, court order, or government regulation
              </li>
              <li>
                <span className="text-ink">Safety & security:</span> To
                protect the rights, safety, and property of Doqto, our users,
                or the public
              </li>
              <li>
                <span className="text-ink">Business transfers:</span> In
                connection with a merger, acquisition, or sale of assets, with
                appropriate privacy protections
              </li>
            </ul>
          </section>

          {/* 7 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">7.</span>Data Retention
            </h2>
            <p className="text-ink-soft leading-relaxed">
              We retain your account information for as long as your account is
              active or as needed to provide the Service. Encrypted message data
              is retained in accordance with HIPAA retention requirements
              (minimum six years for compliance records). Usage data and
              analytics are retained in aggregated, de-identified form. Upon
              account termination, we will delete or de-identify your personal
              information within 30 days, except where retention is required by
              law or our BAA obligations.
            </p>
          </section>

          {/* 8 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">8.</span>Your Rights
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              Depending on your jurisdiction, you may have the following rights:
            </p>
            <ul className="list-disc list-inside text-ink-soft space-y-2 ml-4">
              <li>
                <span className="text-ink">Access:</span> Request a copy of
                the personal information we hold about you
              </li>
              <li>
                <span className="text-ink">Correction:</span> Request that we
                correct inaccurate or incomplete information
              </li>
              <li>
                <span className="text-ink">Deletion:</span> Request that we
                delete your personal information, subject to legal retention
                requirements
              </li>
              <li>
                <span className="text-ink">Portability:</span> Request a copy
                of your data in a structured, machine-readable format
              </li>
              <li>
                <span className="text-ink">Restriction:</span> Request that
                we limit how we use your information
              </li>
              <li>
                <span className="text-ink">HIPAA rights:</span> If applicable,
                you have rights under HIPAA to access, amend, and receive an
                accounting of disclosures of your PHI
              </li>
            </ul>
            <p className="text-ink-soft leading-relaxed mt-4">
              To exercise any of these rights, contact us at{" "}
              <a
                href="mailto:privacy@doqto.ai"
                className="text-primary hover:underline"
              >
                privacy@doqto.ai
              </a>
              .
            </p>
          </section>

          {/* 9 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">9.</span>Security Measures
            </h2>
            <p className="text-ink-soft leading-relaxed">
              We implement comprehensive security measures to protect your data,
              including AES-256 end-to-end encryption, TLS 1.3 for data in
              transit, encrypted data at rest, regular security audits and
              penetration testing, role-based access controls, multi-factor
              authentication, continuous monitoring and intrusion detection, and
              employee security training. For more details, see our{" "}
              <a href="/hipaa" className="text-primary hover:underline">
                HIPAA Compliance
              </a>{" "}
              page.
            </p>
          </section>

          {/* 10 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">10.</span>Cookies & Tracking
            </h2>
            <p className="text-ink-soft leading-relaxed">
              We use essential cookies to maintain your session and
              authentication state. We may use analytics cookies to understand
              how the Service is used, in aggregated and de-identified form. We
              do not use third-party advertising cookies or tracking pixels. You
              can manage cookie preferences through your browser settings,
              though disabling essential cookies may affect Service
              functionality.
            </p>
          </section>

          {/* 11 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">11.</span>Children&apos;s
              Privacy
            </h2>
            <p className="text-ink-soft leading-relaxed">
              The Service is not directed at individuals under the age of 18. We
              do not knowingly collect personal information from children. If we
              become aware that we have inadvertently collected information from
              a minor, we will promptly delete it and terminate the associated
              account.
            </p>
          </section>

          {/* 12 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">12.</span>International Data
              Transfers
            </h2>
            <p className="text-ink-soft leading-relaxed">
              Your information may be processed in the United States or other
              jurisdictions where our service providers operate. We ensure that
              any international data transfers comply with applicable data
              protection laws and that appropriate safeguards are in place,
              including Standard Contractual Clauses where required. All
              transfers involving PHI comply with HIPAA requirements.
            </p>
          </section>

          {/* 13 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">13.</span>Changes to This
              Privacy Policy
            </h2>
            <p className="text-ink-soft leading-relaxed">
              We may update this Privacy Policy from time to time. We will
              notify you of material changes by posting the revised policy on
              the Service and updating the &quot;Last updated&quot; date. For
              significant changes affecting how we handle PHI, we will provide
              direct notice via the Service or email. Your continued use of the
              Service after changes are posted constitutes acceptance of the
              revised policy.
            </p>
          </section>

          {/* 14 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">14.</span>Contact Information
            </h2>
            <p className="text-ink-soft leading-relaxed">
              If you have questions about this Privacy Policy or wish to
              exercise your privacy rights, please contact us:
            </p>
            <div className="mt-4 text-ink-soft">
              <p className="text-ink font-medium">
                DOQTO LLC — Data Protection Officer
              </p>
              <p>
                Email:{" "}
                <a
                  href="mailto:privacy@doqto.ai"
                  className="text-primary hover:underline"
                >
                  privacy@doqto.ai
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
