import type { Metadata } from "next";
import Script from "next/script";
import { Inter } from "next/font/google";
import SmoothScrollProvider from "@/providers/SmoothScrollProvider";
import "./globals.css";

const inter = Inter({
  subsets: ["latin"],
  variable: "--font-inter",
  display: "swap",
});

export const metadata: Metadata = {
  title: "Doqto — Secure Healthcare Messaging",
  description:
    "HIPAA-compliant messaging platform with E2E encryption, voice messaging, and organization management. Built for healthcare teams.",
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
      "HIPAA-compliant messaging with E2E encryption. Built for healthcare teams.",
    type: "website",
    siteName: "Doqto",
  },
  twitter: {
    card: "summary_large_image",
    title: "Doqto — Secure Healthcare Messaging",
    description: "HIPAA-compliant messaging with E2E encryption.",
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
    <html lang="en" className={inter.variable}>
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
