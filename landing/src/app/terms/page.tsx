import type { Metadata } from "next";
import Navbar from "@/components/layout/Navbar";
import Footer from "@/components/layout/Footer";

export const metadata: Metadata = {
  title: "Terms of Service | Doqto",
  description:
    "Terms of Service for Doqto — HIPAA-compliant healthcare messaging platform with E2E encryption.",
};

export default function TermsPage() {
  return (
    <>
      <Navbar />
      <main className="bg-cream min-h-screen pt-24 pb-16">
        <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8">
          <h1 className="text-4xl sm:text-5xl font-bold text-ink mb-4">
            Terms of Service
          </h1>
          <p className="text-ink-soft mb-12">Last updated: November 2026</p>

          {/* 1 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">1.</span>Acceptance of Terms
            </h2>
            <p className="text-ink-soft leading-relaxed">
              By accessing or using the Doqto platform (&quot;Service&quot;),
              you agree to be bound by these Terms of Service
              (&quot;Terms&quot;). If you do not agree to all of these Terms, do
              not use the Service. These Terms constitute a legally binding
              agreement between you and DOQTO LLC (&quot;Company,&quot;
              &quot;we,&quot; &quot;us,&quot; or &quot;our&quot;). Your continued
              use of the Service following any modifications to these Terms
              constitutes acceptance of those changes.
            </p>
          </section>

          {/* 2 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">2.</span>Description of
              Service
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              Doqto is a HIPAA-compliant healthcare messaging platform
              designed for healthcare professionals and organizations. The
              Service includes:
            </p>
            <ul className="list-disc list-inside text-ink-soft space-y-2 ml-4">
              <li>
                End-to-end encrypted messaging for secure clinical
                communications
              </li>
              <li>Organization and department management tools</li>
              <li>Secure file sharing and media exchange</li>
              <li>Real-time messaging with read receipts and typing indicators</li>
              <li>User profile and credential management</li>
            </ul>
          </section>

          {/* 3 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">3.</span>Eligibility
            </h2>
            <p className="text-ink-soft leading-relaxed">
              The Service is intended for use by licensed healthcare
              professionals, HIPAA-covered entities, business associates, and
              their authorized workforce members. By using the Service, you
              represent that you are at least 18 years of age, are authorized to
              use the Service on behalf of your organization (if applicable),
              and that your use complies with all applicable federal, state, and
              local laws and regulations, including but not limited to HIPAA, the
              HITECH Act, and applicable state privacy laws.
            </p>
          </section>

          {/* 4 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">4.</span>User Accounts &
              Registration
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              To use the Service, you must create an account by providing
              accurate and complete information. You are responsible for:
            </p>
            <ul className="list-disc list-inside text-ink-soft space-y-2 ml-4">
              <li>
                Maintaining the confidentiality of your account credentials
              </li>
              <li>All activities that occur under your account</li>
              <li>Promptly notifying us of any unauthorized use of your account</li>
              <li>
                Ensuring that your account information remains accurate and
                up-to-date
              </li>
            </ul>
            <p className="text-ink-soft leading-relaxed mt-4">
              We reserve the right to suspend or terminate accounts that violate
              these Terms or that we reasonably believe have been compromised.
            </p>
          </section>

          {/* 5 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">5.</span>Acceptable Use Policy
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              You agree not to use the Service to:
            </p>
            <ul className="list-disc list-inside text-ink-soft space-y-2 ml-4">
              <li>
                Violate any applicable law, regulation, or third-party rights
              </li>
              <li>
                Transmit any material that is unlawful, harmful, threatening,
                abusive, or otherwise objectionable
              </li>
              <li>
                Attempt to gain unauthorized access to any part of the Service
                or its related systems
              </li>
              <li>
                Interfere with or disrupt the integrity or performance of the
                Service
              </li>
              <li>
                Use the Service for any purpose other than legitimate healthcare
                communications and operations
              </li>
              <li>
                Reverse engineer, decompile, or disassemble any part of the
                Service
              </li>
              <li>
                Share Protected Health Information (PHI) outside of the
                platform&apos;s encrypted channels
              </li>
            </ul>
          </section>

          {/* 6 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">6.</span>HIPAA & Compliance
              Obligations
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              Doqto operates as a Business Associate under HIPAA. We will
              enter into a Business Associate Agreement (BAA) with each Covered
              Entity that uses our Service. You acknowledge and agree that:
            </p>
            <ul className="list-disc list-inside text-ink-soft space-y-2 ml-4">
              <li>
                You are responsible for ensuring your use of the Service
                complies with HIPAA and all applicable regulations
              </li>
              <li>
                You will only share PHI through the Service in accordance with
                HIPAA&apos;s minimum necessary standard
              </li>
              <li>
                You will promptly report any suspected security incidents or
                breaches to us
              </li>
              <li>
                You will maintain appropriate administrative, physical, and
                technical safeguards on your end
              </li>
            </ul>
          </section>

          {/* 7 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">7.</span>Intellectual Property
            </h2>
            <p className="text-ink-soft leading-relaxed">
              All rights, title, and interest in the Service, including but not
              limited to software, design, text, graphics, logos, and
              trademarks, are owned by DOQTO LLC or its licensors. You are
              granted a limited, non-exclusive, non-transferable, revocable
              license to use the Service in accordance with these Terms. You may
              not copy, modify, distribute, sell, or lease any part of the
              Service without our prior written consent. Content you create or
              transmit through the Service remains your property, subject to our
              right to process it as necessary to provide the Service.
            </p>
          </section>

          {/* 8 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">8.</span>Data Security &
              Encryption
            </h2>
            <p className="text-ink-soft leading-relaxed">
              Doqto employs industry-leading security measures, including
              AES-256 end-to-end encryption for all messages and file transfers.
              While we take every reasonable precaution to protect your data, no
              method of electronic transmission or storage is 100% secure. You
              acknowledge that you use the Service at your own risk and that we
              cannot guarantee absolute security. We will notify you and
              applicable authorities of any data breach in accordance with HIPAA
              and applicable state breach notification laws.
            </p>
          </section>

          {/* 9 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">9.</span>Limitation of
              Liability
            </h2>
            <p className="text-ink-soft leading-relaxed">
              To the maximum extent permitted by applicable law, DOQTO LLC,
              its officers, directors, employees, and agents shall not be liable
              for any indirect, incidental, special, consequential, or punitive
              damages, including but not limited to loss of profits, data, or
              goodwill, arising out of or related to your use of the Service.
              Our total liability for any claims arising under these Terms shall
              not exceed the amount you paid us in the twelve (12) months
              preceding the claim. This limitation applies regardless of the
              theory of liability, whether in contract, tort, strict liability,
              or otherwise.
            </p>
          </section>

          {/* 10 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">10.</span>Indemnification
            </h2>
            <p className="text-ink-soft leading-relaxed">
              You agree to indemnify, defend, and hold harmless DOQTO LLC
              and its affiliates, officers, directors, employees, and agents
              from and against any and all claims, liabilities, damages, losses,
              costs, and expenses (including reasonable attorneys&apos; fees)
              arising out of or related to your use of the Service, your
              violation of these Terms, your violation of any applicable law or
              regulation, or your violation of any third-party rights.
            </p>
          </section>

          {/* 11 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">11.</span>Termination
            </h2>
            <p className="text-ink-soft leading-relaxed">
              We may suspend or terminate your access to the Service at any time
              for any reason, including but not limited to a breach of these
              Terms. Upon termination, your right to use the Service ceases
              immediately. We will handle any PHI in accordance with our BAA
              obligations and applicable law. You may terminate your account at
              any time by contacting us. Provisions that by their nature should
              survive termination shall remain in effect, including but not
              limited to intellectual property, limitation of liability,
              indemnification, and dispute resolution provisions.
            </p>
          </section>

          {/* 12 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">12.</span>Governing Law
            </h2>
            <p className="text-ink-soft leading-relaxed">
              These Terms shall be governed by and construed in accordance with
              the laws of the State of Delaware, without regard to its conflict
              of law provisions. Any disputes arising under these Terms shall be
              resolved exclusively in the state or federal courts located in
              Delaware. You consent to the personal jurisdiction of such courts
              and waive any objections to venue.
            </p>
          </section>

          {/* 13 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">13.</span>Changes to Terms
            </h2>
            <p className="text-ink-soft leading-relaxed">
              We reserve the right to modify these Terms at any time. We will
              notify you of material changes by posting the updated Terms on the
              Service and updating the &quot;Last updated&quot; date. Your
              continued use of the Service after such changes constitutes
              acceptance of the modified Terms. We encourage you to review these
              Terms periodically.
            </p>
          </section>

          {/* 14 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">14.</span>Contact Information
            </h2>
            <p className="text-ink-soft leading-relaxed">
              If you have any questions about these Terms, please contact us at:
            </p>
            <div className="mt-4 text-ink-soft">
              <p className="text-ink font-medium">DOQTO LLC</p>
              <p>
                Email:{" "}
                <a
                  href="mailto:legal@doqto.ai"
                  className="text-primary hover:underline"
                >
                  legal@doqto.ai
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
