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
      {/* Navy emphasis band: the one dark section on the page */}
      <div className="relative overflow-hidden rounded-[2rem] bg-navy py-24 sm:py-28">
        <div className="orb w-[26rem] h-[26rem] bg-primary/45 -top-24 -left-20" />
        <div className="orb w-[22rem] h-[22rem] bg-sky/25 -bottom-24 -right-16 [animation-delay:-7s]" />
        <div className="cta-content relative max-w-3xl mx-auto px-6 sm:px-8 text-center">
          <p className="text-sm uppercase tracking-[0.2em] text-sky mb-6">
            Early access
          </p>
          <h2 className="font-display text-4xl sm:text-5xl lg:text-6xl text-cream leading-[1.08] mb-6">
            Care deserves a <em className="text-sky">calmer</em> conversation.
          </h2>

          <p className="text-lg text-sky leading-relaxed mb-12 max-w-xl mx-auto">
            Join the physicians and care teams already on the Doqto waitlist.
            HIPAA-compliant from message one.
          </p>

          <div className="glass-dark max-w-xl mx-auto mb-10 rounded-[2rem] p-4 sm:p-5">
            <WaitlistForm large />
          </div>

          <p className="text-sm text-sky tracking-wide">
            Free for verified physicians &middot; No credit card &middot; HIPAA compliant from day one
          </p>
        </div>
      </div>
    </section>
  );
}
