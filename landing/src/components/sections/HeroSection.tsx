"use client";

import { useEffect, useRef } from "react";
import gsap from "gsap";
import { SECTION_IDS } from "@/lib/constants";
import { ArrowRight, Mic, Users } from "lucide-react";

const HERO_STATS = [
  { value: "AES-256", label: "End-to-end encrypted" },
  { value: "HIPAA", label: "Compliant from day one" },
  { value: "BAA", label: "Ready for your org" },
] as const;

// Bar heights for the voice-note waveform in the chat illustration.
const WAVEFORM = [8, 16, 10, 20, 12, 16, 8, 18, 10, 14, 8, 16, 10, 14, 8] as const;

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
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  const scrollToWaitlist = () => {
    const lenis = (window as unknown as { lenis?: { scrollTo: (target: string, options?: Record<string, unknown>) => void } }).lenis;
    if (lenis) lenis.scrollTo(`#${SECTION_IDS.cta}`, { offset: -40, duration: 1.4 });
    else document.getElementById(SECTION_IDS.cta)?.scrollIntoView({ behavior: "smooth" });
  };

  return (
    <section ref={sectionRef} id={SECTION_IDS.hero} className="bg-cream pt-32 sm:pt-40 pb-20">
      <div className="max-w-7xl mx-auto px-6 sm:px-8">
        <div className="grid lg:grid-cols-2 gap-12 lg:gap-16 items-center">
          <div>
            <div className="hero-reveal inline-flex items-center rounded-full bg-tint px-4 py-2 text-[13px] font-semibold uppercase tracking-[0.08em] text-primary-dark mb-7">
              HIPAA-compliant &middot; Built for clinicians
            </div>

            <h1 className="hero-reveal font-display text-ink text-5xl sm:text-6xl leading-[1.06]">
              Medicine moves at the speed of a <em>message.</em>
            </h1>

            <p className="hero-reveal mt-6 text-lg text-ink-soft max-w-xl leading-relaxed">
              Doqto is the encrypted messaging platform built for healthcare
              teams — voice notes, transcription, and your whole organization,
              without the compliance headache.
            </p>

            <div className="hero-reveal mt-9 flex flex-wrap items-center gap-5">
              <button
                onClick={scrollToWaitlist}
                className="group inline-flex items-center gap-2.5 rounded-full bg-primary px-8 py-4 text-base font-semibold text-white transition-colors duration-300 hover:bg-primary-dark cursor-pointer"
              >
                Join the waitlist
                <ArrowRight className="w-5 h-5 transition-transform duration-300 group-hover:translate-x-1" />
              </button>
              <span className="text-base text-ink-muted">Free for verified physicians</span>
            </div>
          </div>

          {/* Chat illustration on a tinted panel */}
          <div className="hero-reveal rounded-3xl bg-tint p-6 sm:p-8 flex flex-col gap-4" aria-hidden="true">
            <div className="flex items-center gap-3 pb-4 border-b border-tint-strong">
              <div className="flex items-center justify-center w-12 h-12 rounded-full bg-primary text-white">
                <Users className="w-5.5 h-5.5" strokeWidth={2} />
              </div>
              <div>
                <div className="text-[17px] font-semibold text-ink">Cardiology on-call</div>
                <div className="text-sm text-ink-muted">Group chat, verified members</div>
              </div>
            </div>
            <div className="self-start max-w-[82%] rounded-2xl bg-white px-4.5 py-3.5 text-ink-soft leading-relaxed">
              Can someone look at the echo before rounds?
            </div>
            <div className="self-end max-w-[82%] rounded-2xl bg-primary px-4.5 py-3.5 text-white flex items-center gap-3">
              <Mic className="w-5 h-5 shrink-0" strokeWidth={2} />
              <span className="flex items-center gap-[3px]">
                {WAVEFORM.map((h, i) => (
                  <span key={i} className="w-[3px] rounded-full bg-white" style={{ height: h }} />
                ))}
              </span>
              <span className="text-[15px] font-semibold">Voice note</span>
            </div>
            <div className="self-start max-w-[82%] rounded-2xl bg-white px-4.5 py-3.5 text-ink-soft leading-relaxed">
              Listening now. I will call you in five.
            </div>
          </div>
        </div>

        <div className="hero-reveal mt-16 flex flex-wrap gap-y-6 border-t border-line pt-8">
          {HERO_STATS.map((stat, i) => (
            <div
              key={stat.value}
              className={i === 0 ? "pr-8 sm:pr-12" : "pl-8 sm:pl-12 border-l border-line"}
            >
              <div className="font-display text-2xl text-ink">{stat.value}</div>
              <div className="mt-1 text-sm text-ink-muted">{stat.label}</div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
