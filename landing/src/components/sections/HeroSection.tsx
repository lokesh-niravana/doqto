"use client";

import { useEffect, useRef } from "react";
import Image from "next/image";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { SECTION_IDS } from "@/lib/constants";
import { ArrowRight, Check } from "lucide-react";

gsap.registerPlugin(ScrollTrigger);

const HERO_STATS = [
  { value: "AES-256", label: "Encrypted at rest" },
  { value: "HIPAA", label: "Compliant from day one" },
  { value: "BAA", label: "Ready for your org" },
] as const;

export default function HeroSection() {
  const sectionRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (prefersReduced || !sectionRef.current) return;

    const ctx = gsap.context(() => {
      gsap.fromTo(
        ".hero-reveal",
        { y: 40, opacity: 0 },
        { y: 0, opacity: 1, duration: 1, ease: "power3.out", stagger: 0.12, delay: 0.2 }
      );

      // Parallax: photo drifts slower than the page as the hero scrolls away
      gsap.fromTo(
        ".hero-img",
        { yPercent: 0, scale: 1.06 },
        {
          yPercent: 12,
          scale: 1.06,
          ease: "none",
          scrollTrigger: {
            trigger: sectionRef.current,
            start: "top top",
            end: "bottom top",
            scrub: true,
          },
        }
      );
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  const scrollToWaitlist = () => {
    const lenis = (window as unknown as { lenis?: { scrollTo: (target: string, options?: Record<string, unknown>) => void } }).lenis;
    if (lenis) lenis.scrollTo(`#${SECTION_IDS.cta}`, { offset: -40, duration: 1.4 });
    else document.getElementById(SECTION_IDS.cta)?.scrollIntoView({ behavior: "smooth" });
  };

  return (
    <section ref={sectionRef} id={SECTION_IDS.hero} className="relative px-3 pt-3">
      {/* Full-bleed rounded photo hero — Neko/Function pattern */}
      <div className="relative min-h-[92vh] overflow-hidden rounded-[2rem] flex items-end">
        <Image
          src="/images/hero.jpg"
          alt="Two physicians in a warm modern clinic reviewing a secure conversation"
          fill
          priority
          quality={90}
          className="hero-img object-cover will-change-transform"
          sizes="100vw"
        />
        {/* Warm legibility wash */}
        <div className="absolute inset-0 bg-gradient-to-r from-ink/55 via-ink/20 to-transparent" />
        <div className="absolute inset-0 bg-gradient-to-t from-ink/50 via-transparent to-transparent" />

        <div className="relative w-full max-w-7xl mx-auto px-6 sm:px-10 pb-14 pt-40">
          <div className="max-w-2xl">
            <div className="hero-reveal inline-flex items-center gap-2 rounded-full bg-cream/90 px-4 py-1.5 text-sm text-ink mb-7">
              <Check className="w-3.5 h-3.5 text-primary" />
              HIPAA-compliant &middot; Built for clinicians
            </div>

            <h1 className="hero-reveal font-display text-cream text-5xl sm:text-6xl lg:text-7xl leading-[1.04]">
              Medicine moves at the speed of a <em className="text-cream/90">message.</em>
            </h1>

            <p className="hero-reveal mt-6 text-lg sm:text-xl text-cream/85 max-w-xl leading-relaxed">
              Doqto is the encrypted messaging platform built for healthcare
              teams — voice notes, transcription, and your whole organization,
              without the compliance headache.
            </p>

            <div className="hero-reveal mt-9 flex flex-wrap items-center gap-4">
              <button
                onClick={scrollToWaitlist}
                className="group inline-flex items-center gap-2.5 rounded-full bg-cream px-7 py-4 text-base font-medium text-ink transition-all duration-300 hover:bg-white cursor-pointer"
              >
                Join the waitlist
                <ArrowRight className="w-5 h-5 transition-transform duration-300 group-hover:translate-x-1" />
              </button>
              <span className="text-sm text-cream/70">Free for verified physicians</span>
            </div>
          </div>

          {/* Stat strip — Function pattern */}
          <div className="hero-reveal mt-14 flex flex-wrap gap-y-6 border-t border-cream/25 pt-7">
            {HERO_STATS.map((stat, i) => (
              <div
                key={stat.value}
                className={i === 0 ? "pr-8 sm:pr-12" : "pl-8 sm:pl-12 border-l border-cream/25"}
              >
                <div className="font-display text-2xl text-cream">{stat.value}</div>
                <div className="mt-1 text-sm text-cream/70">{stat.label}</div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
