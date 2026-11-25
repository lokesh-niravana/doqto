import type { Metadata } from "next";
import Navbar from "@/components/layout/Navbar";
import Footer from "@/components/layout/Footer";

export const metadata: Metadata = {
  title: "Business Associate Agreement | Doqto",
  description:
    "Business Associate Agreement (BAA) for Doqto — HIPAA-compliant terms governing the handling of Protected Health Information.",
};

export default function BAAPage() {
  return (
    <>
      <Navbar />
      <main className="bg-cream min-h-screen pt-24 pb-16">
        <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8">
          <h1 className="text-4xl sm:text-5xl font-bold text-ink mb-4">
            Business Associate Agreement
          </h1>
          <p className="text-ink-soft mb-12">Last updated: November 2026</p>

          <div className="bg-card border border-line rounded-xl p-6 mb-12">
            <p className="text-ink-soft leading-relaxed text-sm">
              This Business Associate Agreement (&quot;BAA&quot;) is entered
              into by and between the healthcare organization or provider using
              the Doqto platform (&quot;Covered Entity&quot;) and Doqto,
              Inc. (&quot;Business Associate&quot;). This BAA supplements and is
              made part of the Terms of Service between the parties.
            </p>
          </div>

          {/* 1 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">1.</span>Definitions
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              For purposes of this BAA, the following terms shall have the
              meanings set forth below. Capitalized terms not otherwise defined
              herein shall have the meanings given in HIPAA (45 CFR Parts 160
              and 164):
            </p>
            <ul className="list-disc list-inside text-ink-soft space-y-3 ml-4">
              <li>
                <span className="text-ink">Covered Entity:</span> The
                healthcare organization, provider, or health plan that uses the
                Doqto platform and is subject to HIPAA
              </li>
              <li>
                <span className="text-ink">Business Associate:</span>{" "}
                DOQTO LLC, which creates, receives, maintains, or transmits
                Protected Health Information on behalf of the Covered Entity
              </li>
              <li>
                <span className="text-ink">
                  Protected Health Information (PHI):
                </span>{" "}
                Individually identifiable health information transmitted or
                maintained in any form or medium, as defined under 45 CFR §
                160.103
              </li>
              <li>
                <span className="text-ink">
                  Electronic Protected Health Information (ePHI):
                </span>{" "}
                PHI that is transmitted or maintained in electronic media
              </li>
              <li>
                <span className="text-ink">Security Incident:</span> The
                attempted or successful unauthorized access, use, disclosure,
                modification, or destruction of information or interference with
                system operations in an information system
              </li>
              <li>
                <span className="text-ink">Breach:</span> The acquisition,
                access, use, or disclosure of PHI in a manner not permitted
                under HIPAA that compromises the security or privacy of the PHI,
                as defined under 45 CFR § 164.402
              </li>
            </ul>
          </section>

          {/* 2 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">2.</span>Obligations of
              Business Associate
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              Business Associate agrees to:
            </p>
            <ul className="list-disc list-inside text-ink-soft space-y-3 ml-4">
              <li>
                Not use or disclose PHI other than as permitted or required by
                this BAA or as required by law
              </li>
              <li>
                Use appropriate safeguards, including implementing
                administrative, physical, and technical safeguards that
                reasonably protect the confidentiality, integrity, and
                availability of ePHI
              </li>
              <li>
                Report to Covered Entity any use or disclosure of PHI not
                provided for by this BAA of which it becomes aware, including
                Breaches of unsecured PHI as required by 45 CFR § 164.410
              </li>
              <li>
                Ensure that any subcontractors that create, receive, maintain,
                or transmit PHI on behalf of the Business Associate agree to the
                same restrictions and conditions
              </li>
              <li>
                Make PHI available to Covered Entity as necessary to satisfy
                Covered Entity&apos;s obligations under HIPAA
              </li>
              <li>
                Make its internal practices, records, and books relating to the
                use and disclosure of PHI available to the Secretary of Health
                and Human Services for purposes of determining compliance
              </li>
              <li>
                Comply with the HIPAA Security Rule requirements applicable to
                Business Associates
              </li>
            </ul>
          </section>

          {/* 3 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">3.</span>Permitted Uses and
              Disclosures of PHI
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              Business Associate may use or disclose PHI only as follows:
            </p>
            <ul className="list-disc list-inside text-ink-soft space-y-3 ml-4">
              <li>
                As necessary to perform services for or on behalf of Covered
                Entity under the Terms of Service, provided that such use or
                disclosure would not violate HIPAA if done by Covered Entity
              </li>
              <li>
                As required by law, including but not limited to compliance with
                HIPAA, court orders, or lawful government requests
              </li>
              <li>
                For the proper management and administration of Business
                Associate, provided that disclosures are required by law or
                Business Associate obtains reasonable assurances from the
                recipient that the PHI will be held confidentially
              </li>
              <li>
                To provide data aggregation services relating to the healthcare
                operations of Covered Entity, if permitted under the Terms of
                Service
              </li>
            </ul>
          </section>

          {/* 4 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">4.</span>Safeguards
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              Business Associate shall implement and maintain safeguards
              including:
            </p>

            <h3 className="text-ink font-medium mb-2 mt-6">
              Administrative Safeguards
            </h3>
            <ul className="list-disc list-inside text-ink-soft space-y-2 ml-4">
              <li>Designation of a Security Officer and Privacy Officer</li>
              <li>
                Workforce training on HIPAA compliance and information security
              </li>
              <li>Risk analysis and management program</li>
              <li>Sanction policies for workforce violations</li>
              <li>Contingency planning and disaster recovery procedures</li>
            </ul>

            <h3 className="text-ink font-medium mb-2 mt-6">
              Physical Safeguards
            </h3>
            <ul className="list-disc list-inside text-ink-soft space-y-2 ml-4">
              <li>
                Facility access controls for data centers and offices
              </li>
              <li>Workstation and device security policies</li>
              <li>Media disposal and re-use procedures</li>
            </ul>

            <h3 className="text-ink font-medium mb-2 mt-6">
              Technical Safeguards
            </h3>
            <ul className="list-disc list-inside text-ink-soft space-y-2 ml-4">
              <li>
                AES-256 end-to-end encryption for all communications and file
                transfers
              </li>
              <li>TLS 1.3 encryption for data in transit</li>
              <li>Encryption of data at rest</li>
              <li>
                Unique user identification and role-based access controls
              </li>
              <li>Automatic session timeouts and audit logging</li>
              <li>Integrity controls to prevent unauthorized data alteration</li>
            </ul>
          </section>

          {/* 5 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">5.</span>Reporting of Breaches
              & Security Incidents
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              Business Associate shall report to Covered Entity:
            </p>
            <ul className="list-disc list-inside text-ink-soft space-y-3 ml-4">
              <li>
                Any Breach of unsecured PHI without unreasonable delay and in no
                case later than sixty (60) calendar days after discovery
              </li>
              <li>
                Any Security Incident of which Business Associate becomes aware,
                within a commercially reasonable timeframe
              </li>
              <li>
                The identification of each individual whose PHI has been or is
                reasonably believed to have been affected
              </li>
              <li>
                A description of the nature of the Breach, including the types
                of PHI involved
              </li>
              <li>
                Recommended steps individuals should take to protect themselves
              </li>
              <li>
                A description of what Business Associate is doing to investigate
                and mitigate the Breach and prevent future occurrences
              </li>
            </ul>
          </section>

          {/* 6 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">6.</span>Subcontractors
            </h2>
            <p className="text-ink-soft leading-relaxed">
              Business Associate shall ensure that any subcontractors that
              create, receive, maintain, or transmit PHI on behalf of Business
              Associate agree in writing to the same restrictions, conditions,
              and requirements that apply to Business Associate under this BAA.
              Business Associate shall remain responsible for the acts and
              omissions of its subcontractors to the same extent as if performed
              by Business Associate itself.
            </p>
          </section>

          {/* 7 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">7.</span>Access to PHI /
              Amendment Rights
            </h2>
            <p className="text-ink-soft leading-relaxed">
              Business Associate shall make PHI maintained in a Designated
              Record Set available to Covered Entity as necessary to satisfy
              Covered Entity&apos;s obligations under 45 CFR § 164.524
              (individual access) and 45 CFR § 164.526 (amendment). Business
              Associate shall respond to such requests within fifteen (15)
              business days and shall cooperate with Covered Entity to fulfill
              its obligations to individuals.
            </p>
          </section>

          {/* 8 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">8.</span>Accounting of
              Disclosures
            </h2>
            <p className="text-ink-soft leading-relaxed">
              Business Associate shall maintain and make available to Covered
              Entity the information required to provide an accounting of
              disclosures in accordance with 45 CFR § 164.528. Business
              Associate shall maintain such records for a period of six (6)
              years from the date of the disclosure. The accounting shall
              include the date of disclosure, name and address of the recipient,
              a description of the PHI disclosed, and the purpose of the
              disclosure.
            </p>
          </section>

          {/* 9 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">9.</span>Return or Destruction
              of PHI upon Termination
            </h2>
            <p className="text-ink-soft leading-relaxed">
              Upon termination of this BAA or the underlying Terms of Service,
              Business Associate shall, if feasible, return or destroy all PHI
              received from or created on behalf of Covered Entity. If return or
              destruction is not feasible, Business Associate shall extend the
              protections of this BAA to the PHI and limit further uses and
              disclosures to those purposes that make return or destruction
              infeasible. Business Associate shall certify in writing to Covered
              Entity that PHI has been returned or destroyed, or that return or
              destruction is not feasible.
            </p>
          </section>

          {/* 10 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">10.</span>Term and Termination
            </h2>
            <p className="text-ink-soft leading-relaxed mb-4">
              This BAA shall be effective as of the date Covered Entity first
              uses the Service and shall terminate when all PHI received from or
              created on behalf of Covered Entity has been returned or
              destroyed. Either party may terminate this BAA if it determines
              that the other party has violated a material term of this BAA.
            </p>
            <p className="text-ink-soft leading-relaxed">
              Covered Entity may terminate this BAA and the underlying Terms of
              Service if Business Associate has breached a material term and has
              not cured the breach within thirty (30) days of receiving written
              notice. Termination of this BAA shall constitute termination of
              the Terms of Service to the extent PHI processing is involved.
            </p>
          </section>

          {/* 11 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">11.</span>Miscellaneous
            </h2>
            <ul className="list-disc list-inside text-ink-soft space-y-3 ml-4">
              <li>
                <span className="text-ink">Survival:</span> The obligations
                of Business Associate under Sections 5, 8, and 9 shall survive
                termination of this BAA
              </li>
              <li>
                <span className="text-ink">Interpretation:</span> Any
                ambiguity in this BAA shall be resolved in favor of a meaning
                that permits compliance with HIPAA. In the event of a conflict
                between this BAA and the Terms of Service, this BAA shall
                prevail with respect to PHI
              </li>
              <li>
                <span className="text-ink">Amendment:</span> This BAA may be
                amended only in writing signed by both parties. The parties
                agree to amend this BAA as necessary to comply with changes in
                HIPAA regulations
              </li>
              <li>
                <span className="text-ink">No third-party beneficiaries:</span>{" "}
                Nothing in this BAA shall confer any rights upon any person
                other than the parties and their respective successors and
                assigns
              </li>
              <li>
                <span className="text-ink">Governing law:</span> This BAA
                shall be governed by the laws of the State of Delaware,
                consistent with applicable federal law including HIPAA
              </li>
            </ul>
          </section>

          {/* 12 */}
          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">12.</span>Contact Information
            </h2>
            <p className="text-ink-soft leading-relaxed">
              For questions about this Business Associate Agreement or to report
              a potential breach:
            </p>
            <div className="mt-4 text-ink-soft">
              <p className="text-ink font-medium">
                DOQTO LLC — Privacy Officer
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
