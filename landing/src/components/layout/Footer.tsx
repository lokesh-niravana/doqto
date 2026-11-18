import Link from "next/link";
import { SECTION_IDS } from "@/lib/constants";
import Logo from "@/components/ui/Logo";

const footerLinks = {
  product: [
    { label: "Features", href: `#${SECTION_IDS.features}` },
    { label: "Security", href: `#${SECTION_IDS.security}` },
    { label: "How It Works", href: `#${SECTION_IDS.howItWorks}` },
  ],
  legal: [
    { label: "Privacy Policy", href: "/privacy" },
    { label: "Terms of Service", href: "/terms" },
    { label: "BAA", href: "/baa" },
    { label: "HIPAA Compliance", href: "/hipaa" },
  ],
  contact: [
    { label: "lokesh@doqto.ai", href: "mailto:lokesh@doqto.ai" },
    { label: "Support", href: "#" },
  ],
};

export default function Footer() {
  return (
    <footer className="relative z-10 bg-cream text-ink-soft pt-16 pb-8 border-t border-line">
      <div className="max-w-7xl mx-auto px-6 sm:px-8">
        <div className="grid grid-cols-2 md:grid-cols-4 gap-10 mb-12">
          {/* Brand */}
          <div className="col-span-2 md:col-span-1">
            <div className="mb-4 flex items-center gap-2">
              <Logo size="sm" />
              <span className="font-display text-2xl text-ink">Doqto</span>
            </div>
            <p className="text-sm leading-relaxed max-w-xs">
              HIPAA-compliant healthcare messaging with end-to-end encryption.
              Built for teams that care.
            </p>
            <div className="mt-5 flex items-center gap-3">
            <a
              href="https://www.linkedin.com/company/doqto-ai/"
              target="_blank"
              rel="noopener noreferrer"
              aria-label="Doqto on LinkedIn"
              className="inline-flex h-9 w-9 items-center justify-center rounded-full border border-line text-ink-soft hover:text-primary hover:border-primary transition-colors duration-300"
            >
              <svg
                viewBox="0 0 24 24"
                className="h-4 w-4"
                fill="currentColor"
                aria-hidden="true"
              >
                <path d="M20.45 20.45h-3.56v-5.57c0-1.33-.02-3.04-1.85-3.04-1.85 0-2.14 1.45-2.14 2.94v5.67H9.35V9h3.41v1.56h.05c.48-.9 1.64-1.85 3.37-1.85 3.6 0 4.27 2.37 4.27 5.46v6.28zM5.34 7.43a2.06 2.06 0 1 1 0-4.13 2.06 2.06 0 0 1 0 4.13zM7.12 20.45H3.56V9h3.56v11.45zM22.22 0H1.77C.79 0 0 .77 0 1.73v20.54C0 23.23.79 24 1.77 24h20.45c.98 0 1.78-.77 1.78-1.73V1.73C24 .77 23.2 0 22.22 0z" />
              </svg>
            </a>
            <a
              href="https://www.instagram.com/doqto.ai/"
              target="_blank"
              rel="noopener noreferrer"
              aria-label="Doqto on Instagram"
              className="inline-flex h-9 w-9 items-center justify-center rounded-full border border-line text-ink-soft hover:text-primary hover:border-primary transition-colors duration-300"
            >
              <svg
                viewBox="0 0 24 24"
                className="h-4 w-4"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                aria-hidden="true"
              >
                <rect x="3" y="3" width="18" height="18" rx="5" />
                <circle cx="12" cy="12" r="4" />
                <path d="M17.5 6.5h.01" />
              </svg>
            </a>
            </div>
          </div>

          {(
            [
              ["Product", footerLinks.product],
              ["Legal", footerLinks.legal],
              ["Contact", footerLinks.contact],
            ] as const
          ).map(([heading, links]) => (
            <div key={heading}>
              <h4 className="text-ink font-medium text-xs mb-4 uppercase tracking-[0.15em]">
                {heading}
              </h4>
              <ul className="space-y-3">
                {links.map((link) => (
                  <li key={link.label}>
                    {link.href.startsWith("/") ? (
                      <Link
                        href={link.href}
                        className="text-sm hover:text-primary transition-colors duration-300"
                      >
                        {link.label}
                      </Link>
                    ) : (
                      <a
                        href={link.href}
                        className="text-sm hover:text-primary transition-colors duration-300"
                      >
                        {link.label}
                      </a>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>

        {/* Bottom bar */}
        <div className="pt-8 border-t border-line flex flex-col sm:flex-row items-center justify-between gap-4">
          <p className="text-xs">
            &copy; {new Date().getFullYear()} DOQTO LLC &middot; 11213 Delmar
            St, Leawood, KS 66211. All rights reserved.
          </p>
          <p className="text-xs tracking-wide">
            HIPAA Compliant &middot; AES-256 Encrypted
          </p>
        </div>
      </div>
    </footer>
  );
}
