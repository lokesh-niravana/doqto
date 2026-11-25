import type { Metadata } from "next";
import Navbar from "@/components/layout/Navbar";
import Footer from "@/components/layout/Footer";

export const metadata: Metadata = {
  title: "Support | Doqto",
  description:
    "How to reach the Doqto team, and answers to the most common questions about signing in, NPI verification, notifications and your account.",
};

const faqs: { q: string; a: React.ReactNode }[] = [
  {
    q: "I did not receive my verification code.",
    a: (
      <>
        Codes arrive by SMS within a minute. Check that the number you entered
        is a US mobile number and that your carrier does not block short-code
        messages. If a second attempt fails, email us the last four digits of
        your number and we will look at the delivery log.
      </>
    ),
  },
  {
    q: "My NPI is not found or shows someone else.",
    a: (
      <>
        Doqto verifies physicians against the federal NPPES registry. A brand
        new NPI can take a few days to appear there, and a registry entry that
        still shows a previous name or practice will show that way in Doqto
        until NPPES is updated. Email us with your NPI and we will check the
        record with you.
      </>
    ),
  },
  {
    q: "I am not getting notifications.",
    a: (
      <>
        Open <span className="text-ink">Settings</span> in the app and make
        sure notifications are on, then check iOS or Android Settings for
        Doqto. Focus modes and battery savers on Android can delay messages;
        allowing Doqto to run in the background fixes that.
      </>
    ),
  },
  {
    q: "How do I join my practice or hospital?",
    a: (
      <>
        Go to <span className="text-ink">My Org</span> and search for your
        organization, or enter the invite code your administrator shared. An
        administrator approves new members; until then you can still message
        connected colleagues.
      </>
    ),
  },
  {
    q: "How do I report a message or block someone?",
    a: (
      <>
        Long-press any message and choose{" "}
        <span className="text-ink">Report</span>. On a doctor&apos;s profile,
        the <span className="text-ink">...</span> menu offers{" "}
        <span className="text-ink">Report</span> and{" "}
        <span className="text-ink">Block</span>. Reports go to your
        organization&apos;s administrators and to the Doqto team, and blocking
        is never visible to the other person.
      </>
    ),
  },
  {
    q: "How do I delete my account?",
    a: (
      <>
        Open <span className="text-ink">Settings</span>, tap{" "}
        <span className="text-ink">Delete account</span> and confirm. The
        account is deleted immediately. Details, including how to delete
        without access to the app, are on the{" "}
        <a href="/delete-account" className="text-primary">
          account deletion page
        </a>
        .
      </>
    ),
  },
];

export default function SupportPage() {
  return (
    <>
      <Navbar />
      <main className="bg-cream min-h-screen pt-24 pb-16">
        <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8">
          <h1 className="text-4xl sm:text-5xl font-bold text-ink mb-4">
            Support
          </h1>
          <p className="text-ink-soft mb-12">
            Doqto is made by DOQTO LLC in Leawood, Kansas. A person on the team
            reads every message.
          </p>

          <section className="mb-12">
            <h2 className="text-xl font-semibold text-ink mb-4">Contact us</h2>
            <ul className="space-y-3 text-ink-soft leading-relaxed">
              <li>
                <span className="text-ink">Email:</span>{" "}
                <a href="mailto:support@doqto.ai" className="text-primary">
                  support@doqto.ai
                </a>
                . We reply within one business day, usually faster.
              </li>
              <li>
                <span className="text-ink">Privacy and data requests:</span>{" "}
                <a href="mailto:privacy@doqto.ai" className="text-primary">
                  privacy@doqto.ai
                </a>
                .
              </li>
              <li>
                <span className="text-ink">Security issues:</span> email{" "}
                <a
                  href="mailto:support@doqto.ai?subject=Security%20report"
                  className="text-primary"
                >
                  support@doqto.ai
                </a>{" "}
                with &quot;Security report&quot; in the subject. We acknowledge
                reports within one business day and do not pursue researchers
                who report in good faith.
              </li>
              <li>
                Doqto is not for emergencies. If a patient needs urgent care,
                use your local emergency number.
              </li>
            </ul>
          </section>

          <section className="mb-12">
            <h2 className="text-xl font-semibold text-ink mb-6">
              Common questions
            </h2>
            <div className="space-y-8">
              {faqs.map((f) => (
                <div key={f.q}>
                  <h3 className="font-semibold text-ink mb-2">{f.q}</h3>
                  <p className="text-ink-soft leading-relaxed">{f.a}</p>
                </div>
              ))}
            </div>
          </section>

          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              When you write to us
            </h2>
            <p className="text-ink-soft leading-relaxed">
              Include the phone number on your account, your device model and
              operating system version, and what you expected to happen. Please
              do not include patient information in email; if the question
              involves a specific message, tell us the time it was sent and we
              will take it from there inside the app&apos;s audit tools.
            </p>
          </section>

          <p className="text-ink-soft leading-relaxed">
            See also the{" "}
            <a href="/privacy" className="text-primary">
              Privacy Policy
            </a>
            , the{" "}
            <a href="/terms" className="text-primary">
              Terms of Service
            </a>{" "}
            and our{" "}
            <a href="/hipaa" className="text-primary">
              HIPAA compliance
            </a>{" "}
            page.
          </p>
        </div>
      </main>
      <Footer />
    </>
  );
}
