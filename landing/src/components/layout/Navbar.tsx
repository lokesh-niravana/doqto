"use client";

import { useState, useEffect } from "react";
import { cn } from "@/lib/utils";
import { NAV_LINKS } from "@/lib/constants";
import { ArrowRight, Menu, X } from "lucide-react";
import Logo from "@/components/ui/Logo";

export default function Navbar() {
  const [scrolled, setScrolled] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);

  useEffect(() => {
    const handleScroll = () => setScrolled(window.scrollY > 20);
    window.addEventListener("scroll", handleScroll, { passive: true });
    return () => window.removeEventListener("scroll", handleScroll);
  }, []);

  const scrollTo = (href: string) => {
    setMobileOpen(false);
    const id = href.replace("#", "");
    const lenis = (window as unknown as { lenis?: { scrollTo: (target: string, options?: Record<string, unknown>) => void } }).lenis;
    if (lenis) {
      lenis.scrollTo(`#${id}`, { offset: -96, duration: 1.2 });
    } else {
      document.getElementById(id)?.scrollIntoView({ behavior: "smooth" });
    }
  };

  return (
    <>
      {/* Floating pill nav — Superpower pattern */}
      <nav className="fixed top-4 left-0 right-0 z-50 px-4">
        <div
          className={cn(
            "mx-auto flex items-center justify-between gap-4 rounded-full pl-4 pr-2 py-2 transition-all duration-500",
            scrolled
              ? "max-w-3xl bg-card/85 navbar-glass border border-line shadow-lg shadow-ink/5"
              : "max-w-6xl bg-transparent border border-transparent"
          )}
        >
          <button onClick={() => scrollTo("#hero")} className="flex items-center gap-2 cursor-pointer">
            <Logo size="sm" />
            <span
              className={cn(
                "font-display text-xl transition-colors duration-500",
                "text-ink"
              )}
            >
              Doqto
            </span>
          </button>

          <div className="hidden md:flex items-center gap-7">
            {NAV_LINKS.map((link) => (
              <button
                key={link.href}
                onClick={() => scrollTo(link.href)}
                className={cn(
                  "text-sm transition-colors duration-500 cursor-pointer",
                  "text-ink-soft hover:text-ink"
                )}
              >
                {link.label}
              </button>
            ))}
          </div>

          <div className="hidden md:block">
            <button
              onClick={() => scrollTo("#join-waitlist")}
              className={cn(
                "group inline-flex items-center gap-2 rounded-full px-5 py-2.5 text-sm font-medium transition-colors duration-500 cursor-pointer",
                "bg-primary text-white hover:bg-primary-dark"
              )}
            >
              Join the waitlist
              <ArrowRight className="w-4 h-4 transition-transform duration-300 group-hover:translate-x-0.5" />
            </button>
          </div>

          <button
            className="md:hidden p-2 cursor-pointer"
            onClick={() => setMobileOpen(!mobileOpen)}
            aria-label={mobileOpen ? "Close menu" : "Open menu"}
          >
            {mobileOpen ? (
              <X className="w-6 h-6 text-ink" />
            ) : (
              <Menu className="w-6 h-6 text-ink" />
            )}
          </button>
        </div>
      </nav>

      {/* Mobile drawer */}
      <div
        className={cn(
          "fixed inset-0 z-40 md:hidden transition-all duration-300",
          mobileOpen ? "visible" : "invisible"
        )}
      >
        <div
          className={cn(
            "absolute inset-0 bg-ink/20 backdrop-blur-sm transition-opacity duration-300",
            mobileOpen ? "opacity-100" : "opacity-0"
          )}
          onClick={() => setMobileOpen(false)}
        />
        <div
          className={cn(
            "absolute top-20 right-4 left-4 bg-card rounded-3xl border border-line shadow-2xl p-6 transition-all duration-300",
            mobileOpen ? "opacity-100 translate-y-0" : "opacity-0 -translate-y-4"
          )}
        >
          <div className="flex flex-col gap-1">
            {NAV_LINKS.map((link) => (
              <button
                key={link.href}
                onClick={() => scrollTo(link.href)}
                className="text-left px-4 py-3 text-ink font-medium rounded-xl hover:bg-cream transition-colors cursor-pointer"
              >
                {link.label}
              </button>
            ))}
            <div className="mt-4 pt-4 border-t border-line">
              <button
                onClick={() => scrollTo("#join-waitlist")}
                className="w-full inline-flex items-center justify-center gap-2 rounded-full bg-primary px-5 py-3 font-medium text-white cursor-pointer"
              >
                Join the waitlist
                <ArrowRight className="w-4 h-4" />
              </button>
            </div>
          </div>
        </div>
      </div>
    </>
  );
}
