"use client";

import { useEffect, useRef } from "react";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { SECTION_IDS, TESTIMONIALS } from "@/lib/constants";

gsap.registerPlugin(ScrollTrigger);

export default function TestimonialsSection() {
  const sectionRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (prefersReduced || !sectionRef.current) return;

    const ctx = gsap.context(() => {
      gsap.fromTo(
        ".testimonial-reveal",
        { y: 50, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.9,
          stagger: 0.15,
          ease: "power3.out",
          scrollTrigger: { trigger: sectionRef.current, start: "top 75%" },
        }
      );
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} id={SECTION_IDS.testimonials} className="py-28 sm:py-36">
      <div className="max-w-6xl mx-auto px-6 sm:px-8">
        <p className="testimonial-reveal text-sm uppercase tracking-[0.2em] text-ink-soft text-center mb-16">
          From early-access teams
        </p>

        {/* Editorial columned quotes — Function pattern */}
        <div className="grid md:grid-cols-3">
          {TESTIMONIALS.map((t, i) => (
            <figure
              key={t.name}
              className={
                i === 0
                  ? "testimonial-reveal py-8 md:py-0 md:pr-10"
                  : "testimonial-reveal py-8 md:py-0 md:pl-10 border-t md:border-t-0 md:border-l border-line"
              }
            >
              <blockquote className="font-display text-xl leading-relaxed text-ink">
                &ldquo;{t.quote}&rdquo;
              </blockquote>
              <figcaption className="mt-6">
                <div className="font-medium text-ink">{t.name}</div>
                <div className="mt-0.5 text-sm text-ink-soft">
                  {t.role}, {t.org}
                </div>
              </figcaption>
            </figure>
          ))}
        </div>
      </div>
    </section>
  );
}
