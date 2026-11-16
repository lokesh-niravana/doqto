"use client";

import { useEffect, useRef } from "react";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { SECTION_IDS, SECURITY_FEATURES } from "@/lib/constants";
import { Check } from "lucide-react";

gsap.registerPlugin(ScrollTrigger);

export default function SecuritySection() {
  const sectionRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (prefersReduced || !sectionRef.current) return;

    const ctx = gsap.context(() => {
      gsap.fromTo(
        ".security-reveal",
        { y: 50, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.9,
          stagger: 0.1,
          ease: "power3.out",
          scrollTrigger: { trigger: sectionRef.current, start: "top 75%" },
        }
      );
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} id={SECTION_IDS.security} className="relative py-28 sm:py-36 overflow-hidden">
      <div className="orb w-[26rem] h-[26rem] bg-primary/20 top-1/3 -left-24" />
      <div className="orb w-[22rem] h-[22rem] bg-sky/45 bottom-10 -right-20 [animation-delay:-8s]" />
      {/* Halftone texture — Neko pattern */}
      <div className="halftone absolute inset-x-0 top-0 h-64 opacity-40 pointer-events-none [mask-image:linear-gradient(to_bottom,black,transparent)]" />

      <div className="relative max-w-6xl mx-auto px-6 sm:px-8">
        <div className="security-reveal max-w-2xl mx-auto text-center mb-16">
          <p className="text-sm uppercase tracking-[0.2em] text-ink-soft mb-6">Security</p>
          <h2 className="font-display text-4xl sm:text-5xl lg:text-6xl text-ink leading-[1.08]">
            Compliance isn&rsquo;t a feature. <em>It&rsquo;s the foundation.</em>
          </h2>
          <p className="mt-6 text-lg text-ink-soft leading-relaxed">
            Every layer of Doqto is designed around HIPAA and PHI protection —
            quietly, so your team never has to think about it.
          </p>
        </div>

        {/* Checklist card — Neko pattern */}
        <div className="security-reveal glass relative mx-auto max-w-3xl rounded-[1.75rem] p-8 sm:p-12">
          <ul className="grid sm:grid-cols-2 gap-x-10 gap-y-7">
            {SECURITY_FEATURES.map((item) => (
              <li key={item.title} className="flex items-start gap-4">
                <span className="mt-0.5 shrink-0 w-6 h-6 rounded-full bg-primary/10 flex items-center justify-center">
                  <Check className="w-3.5 h-3.5 text-primary" strokeWidth={2.5} />
                </span>
                <div>
                  <h3 className="font-medium text-ink">{item.title}</h3>
                  <p className="mt-1 text-sm text-ink-soft leading-relaxed">
                    {item.description}
                  </p>
                </div>
              </li>
            ))}
          </ul>
        </div>

        <p className="security-reveal mt-10 text-center text-sm text-ink-soft tracking-wide">
          HIPAA compliant &middot; AES-256-GCM encrypted &middot; BAA available &middot; SOC 2 roadmap
        </p>
      </div>
    </section>
  );
}
