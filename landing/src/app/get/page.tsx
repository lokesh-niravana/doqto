"use client";

import { useEffect, useState } from "react";
import Navbar from "@/components/layout/Navbar";
import Footer from "@/components/layout/Footer";

// The link doctors share from "Invite a colleague" in the app. Android goes
// straight to the Play Store. An iPhone or iPad never sees another
// platform's store: it goes to the App Store once the listing is live, and
// until then gets plain instructions.
const PLAY_URL = "https://play.google.com/store/apps/details?id=com.doqto.app";
// Set once the App Store listing is live, and iPhones redirect too.
const APP_STORE_URL: string | null = null;

export default function GetTheApp() {
  const [isApple, setIsApple] = useState(false);

  useEffect(() => {
    const ua = navigator.userAgent;
    // iPadOS reports itself as a Mac; the touch points give it away.
    const apple =
      /iphone|ipad|ipod/i.test(ua) ||
      (/macintosh/i.test(ua) && navigator.maxTouchPoints > 1);
    if (/android/i.test(ua)) window.location.replace(PLAY_URL);
    else if (apple && APP_STORE_URL) window.location.replace(APP_STORE_URL);
    else setIsApple(apple);
  }, []);

  return (
    <>
      <Navbar />
      <main className="bg-cream min-h-screen pt-24 pb-16 flex items-center">
        <div className="max-w-lg mx-auto px-4 sm:px-6 lg:px-8 text-center">
          <h1 className="text-3xl sm:text-4xl font-bold text-ink mb-4">
            Join your colleagues on Doqto
          </h1>
          <p className="text-ink-soft leading-relaxed mb-8">
            Secure messaging for doctors. Sign up with your NPI and you&apos;ll be
            connected to the colleague who invited you.
          </p>
          <div className="flex flex-col items-center gap-3">
            {!isApple && (
              <a
                href={PLAY_URL}
                className="inline-block rounded-full bg-primary text-white font-semibold px-8 py-3"
              >
                Get it on Google Play
              </a>
            )}
            {APP_STORE_URL && (
              <a
                href={APP_STORE_URL}
                className="inline-block rounded-full bg-ink text-white font-semibold px-8 py-3"
              >
                Download on the App Store
              </a>
            )}
            {isApple && !APP_STORE_URL && (
              <p className="text-ink-soft text-sm">
                Open Doqto on your iPhone and sign in to connect with the
                colleague who invited you.
              </p>
            )}
          </div>
        </div>
      </main>
      <Footer />
    </>
  );
}
