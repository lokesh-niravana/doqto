import type { Metadata } from "next";
import Navbar from "@/components/layout/Navbar";
import Footer from "@/components/layout/Footer";

export const metadata: Metadata = {
  title: "Delete your account | Doqto",
  description:
    "How to delete your Doqto account and what happens to your data when you do.",
};

export default function DeleteAccountPage() {
  return (
    <>
      <Navbar />
      <main className="bg-cream min-h-screen pt-24 pb-16">
        <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8">
          <h1 className="text-4xl sm:text-5xl font-bold text-ink mb-4">
            Delete your Doqto account
          </h1>
          <p className="text-ink-soft mb-12">
            You can delete your account at any time from inside the app. No
            email or support ticket is needed.
          </p>

          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">1.</span>Delete from the app
            </h2>
            <ol className="list-decimal pl-6 space-y-2 text-ink-soft leading-relaxed">
              <li>Open Doqto and sign in.</li>
              <li>
                Go to <span className="text-ink">Profile</span>, then{" "}
                <span className="text-ink">Settings</span>.
              </li>
              <li>
                Tap <span className="text-ink">Delete account</span>.
              </li>
              <li>
                Type <span className="text-ink">DELETE</span> to confirm. The
                account is deleted immediately and you are signed out.
              </li>
            </ol>
          </section>

          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">2.</span>Can&apos;t access the
              app?
            </h2>
            <p className="text-ink-soft leading-relaxed">
              Email{" "}
              <a href="mailto:privacy@doqto.ai" className="text-primary">
                privacy@doqto.ai
              </a>{" "}
              from the address or phone number on your account and we will
              delete it within 30 days.
            </p>
          </section>

          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">3.</span>What is deleted
            </h2>
            <ul className="list-disc pl-6 space-y-2 text-ink-soft leading-relaxed">
              <li>
                Your profile: name, phone number, email, NPI, specialty,
                photo and bio.
              </li>
              <li>
                Your messages, voice notes and transcripts, attachments,
                scheduled messages and read receipts.
              </li>
              <li>
                Your connections, invitations, group and organization
                memberships, notification settings and device push tokens.
              </li>
            </ul>
          </section>

          <section className="mb-10">
            <h2 className="text-xl font-semibold text-ink mb-4">
              <span className="text-primary mr-2">4.</span>What is kept
            </h2>
            <p className="text-ink-soft leading-relaxed">
              Doqto is a HIPAA-regulated service. Security audit records (for
              example, the timestamp of the deletion itself) are retained for
              six years as required by 45 CFR §164.316(b)(2); they are linked
              to an anonymised account record that no longer holds your name,
              phone number, email or NPI. If your organisation has placed
              conversations under a legal hold, your messages in those
              conversations are hidden from other participants but preserved
              until the hold is lifted, and are then erased. Nothing else is
              kept.
            </p>
          </section>

          <p className="text-ink-soft leading-relaxed">
            See the{" "}
            <a href="/privacy" className="text-primary">
              Privacy Policy
            </a>{" "}
            for full details.
          </p>
        </div>
      </main>
      <Footer />
    </>
  );
}
