"use client";

import { useEffect, useState } from "react";
import Navbar from "@/components/layout/Navbar";
import Footer from "@/components/layout/Footer";

// Stripe sends people here after Checkout, and after the customer portal
// (?status=portal, where nothing may have been paid). The app can't be told directly,
// so this page bounces them back into it via doqto:///billing; the app
// re-checks billing status on resume, so this page never has to know
// whether the webhook has landed yet.
export default function BillingDone() {
  const [status, setStatus] = useState<string | null>(null);
  const cancelled = status === "cancel";
  const portal = status === "portal";

  useEffect(() => {
    const status = new URLSearchParams(window.location.search).get("status");
    setStatus(status);
    if (status !== "cancel") {
      window.location.href = "doqto:///billing";
    }
  }, []);

  return (
    <>
      <Navbar />
      <main className="bg-cream min-h-screen pt-24 pb-16 flex items-center">
        <div className="max-w-lg mx-auto px-4 sm:px-6 lg:px-8 text-center">
          <h1 className="text-3xl sm:text-4xl font-bold text-ink mb-4">
            {cancelled
              ? "Checkout cancelled"
              : portal
                ? "You're all set"
                : "Payment received"}
          </h1>
          <p className="text-ink-soft leading-relaxed mb-8">
            {cancelled
              ? "Nothing was charged. You can subscribe any time from the app."
              : portal
                ? "Returning to Doqto… If it doesn't open automatically, tap the button below."
                : "Thank you. Your subscription is active. Open Doqto to continue — if it doesn't open automatically, tap the button below."}
          </p>
          <a
            href="doqto:///billing"
            className="inline-block rounded-full bg-primary text-white font-semibold px-8 py-3"
          >
            Open Doqto
          </a>
        </div>
      </main>
      <Footer />
    </>
  );
}
