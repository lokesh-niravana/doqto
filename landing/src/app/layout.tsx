import type { Metadata } from "next";
import Script from "next/script";
import { Fraunces, Instrument_Sans } from "next/font/google";
import SmoothScrollProvider from "@/providers/SmoothScrollProvider";
import "./globals.css";

const fraunces = Fraunces({
  subsets: ["latin"],
  variable: "--font-fraunces",
  display: "swap",
  axes: ["SOFT", "WONK", "opsz"],
  style: ["normal", "italic"],
});

const instrument = Instrument_Sans({
  subsets: ["latin"],
  variable: "--font-instrument",
  display: "swap",
});

export const metadata: Metadata = {
  title: "Doqto — Secure Healthcare Messaging",
  description:
    "HIPAA-compliant messaging platform, encrypted in transit and at rest, with voice messaging and organization management. Built for healthcare teams.",
  keywords: [
    "HIPAA compliant messaging",
    "healthcare communication",
    "encrypted messaging",
    "medical messaging app",
    "secure healthcare chat",
  ],
  icons: {
    icon: [
      { url: "/favicon.ico", sizes: "48x48" },
      { url: "/favicon-32x32.png", sizes: "32x32", type: "image/png" },
      { url: "/favicon-16x16.png", sizes: "16x16", type: "image/png" },
      { url: "/android-chrome-192x192.png", sizes: "192x192", type: "image/png" },
    ],
    apple: "/apple-touch-icon.png",
  },
  openGraph: {
    title: "Doqto — Secure Healthcare Messaging",
    description:
      "HIPAA-compliant messaging, encrypted in transit and at rest. Built for healthcare teams.",
    type: "website",
    siteName: "Doqto",
  },
  twitter: {
    card: "summary_large_image",
    title: "Doqto — Secure Healthcare Messaging",
    description: "HIPAA-compliant messaging, encrypted in transit and at rest.",
  },
  robots: {
    index: true,
    follow: true,
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className={`${fraunces.variable} ${instrument.variable}`}>
      <body className="bg-cream text-ink antialiased">
        <SmoothScrollProvider>{children}</SmoothScrollProvider>
        <Script
          src="https://www.googletagmanager.com/gtag/js?id=G-QVZW44YQCK"
          strategy="afterInteractive"
        />
        <Script id="gtag-init" strategy="afterInteractive">
          {`
            window.dataLayer = window.dataLayer || [];
            function gtag(){dataLayer.push(arguments);}
            gtag('js', new Date());
            gtag('config', 'G-QVZW44YQCK');
          `}
        </Script>
      </body>
    </html>
  );
}
