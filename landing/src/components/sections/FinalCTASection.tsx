"use client";

import { useEffect, useRef } from "react";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { SECTION_IDS } from "@/lib/constants";
import WaitlistForm from "@/components/ui/WaitlistForm";

gsap.registerPlugin(ScrollTrigger);

export default function FinalCTASection() {
  const sectionRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (prefersReduced || !sectionRef.current) return;

    const ctx = gsap.context(() => {
      gsap.fromTo(
        ".cta-content",
        { y: 60, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.8,
          ease: "power3.out",
          scrollTrigger: { trigger: sectionRef.current, start: "top 75%" },
        }
      );
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} id={SECTION_IDS.cta} className="px-3 pb-3">
      {/* Dark ink card — mirrors the hero's rounded full-bleed frame */}
      <div className="relative overflow-hidden rounded-[2rem] bg-ink py-28 sm:py-36">
        <div className="halftone absolute inset-x-0 bottom-0 h-72 opacity-[0.15] pointer-events-none [mask-image:linear-gradient(to_top,black,transparent)]" />

        <div className="cta-content relative max-w-3xl mx-auto px-6 sm:px-8 text-center">
          <p className="text-sm uppercase tracking-[0.2em] text-cream/60 mb-6">
            Early access
          </p>
          <h2 className="font-display text-4xl sm:text-5xl lg:text-6xl text-cream leading-[1.08] mb-6">
            Care deserves a <em className="text-cream/85">calmer</em> conversation.
          </h2>

          <p className="text-lg text-cream/70 leading-relaxed mb-12 max-w-xl mx-auto">
            Join the physicians and care teams already on the Doqto waitlist.
            HIPAA-compliant from message one.
          </p>

          <div className="max-w-lg mx-auto mb-10">
            <WaitlistForm large />
          </div>

          <p className="text-sm text-cream/50 tracking-wide">
            Free for verified physicians &middot; No credit card &middot; HIPAA compliant from day one
          </p>
        </div>
      </div>
    </section>
  );
}
