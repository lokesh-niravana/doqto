"use client";

import { useEffect, useRef } from "react";
import Image from "next/image";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { SECTION_IDS, STEPS } from "@/lib/constants";

gsap.registerPlugin(ScrollTrigger);

const STEP_IMAGES = ["/images/step-1.jpg", "/images/step-2.jpg", "/images/step-3.jpg"];

export default function HowItWorksSection() {
  const sectionRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (prefersReduced || !sectionRef.current) return;

    const ctx = gsap.context(() => {
      gsap.fromTo(
        ".hiw-heading",
        { y: 50, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.9,
          ease: "power3.out",
          scrollTrigger: { trigger: sectionRef.current, start: "top 75%" },
        }
      );
      gsap.fromTo(
        ".hiw-card",
        { y: 60, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.8,
          stagger: 0.18,
          ease: "power3.out",
          scrollTrigger: { trigger: ".hiw-steps", start: "top 80%" },
        }
      );

      // Parallax drift inside each step photo frame
      gsap.utils.toArray<HTMLElement>(".hiw-img").forEach((img) => {
        gsap.fromTo(
          img,
          { yPercent: -7, scale: 1.15 },
          {
            yPercent: 7,
            scale: 1.15,
            ease: "none",
            scrollTrigger: {
              trigger: img,
              start: "top bottom",
              end: "bottom top",
              scrub: true,
            },
          }
        );
      });
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} id={SECTION_IDS.howItWorks} className="py-28 sm:py-36">
      <div className="max-w-7xl mx-auto px-6 sm:px-8">
        <div className="hiw-heading text-center max-w-2xl mx-auto mb-16">
          <p className="text-sm uppercase tracking-[0.2em] text-ink-soft mb-6">
            How it works
          </p>
          <h2 className="font-display text-4xl sm:text-5xl lg:text-6xl text-ink leading-[1.08]">
            From sign-up to first message in <em>minutes.</em>
          </h2>
        </div>

        {/* Numbered image cards — Superpower pattern */}
        <div className="hiw-steps grid md:grid-cols-3 gap-6 lg:gap-8">
          {STEPS.map((step, i) => (
            <div key={step.step} className="hiw-card group">
              <div className="relative aspect-[4/3] overflow-hidden rounded-[1.5rem]">
                <Image
                  src={STEP_IMAGES[i]}
                  alt={step.title}
                  fill
                  quality={88}
                  className="hiw-img object-cover will-change-transform"
                  sizes="(min-width: 768px) 33vw, 100vw"
                />
                <span className="absolute top-4 left-4 w-9 h-9 rounded-xl bg-cream/90 backdrop-blur flex items-center justify-center font-display text-lg text-ink">
                  {step.step}
                </span>
              </div>
              <h3 className="mt-6 font-display text-2xl text-ink">{step.title}</h3>
              <p className="mt-2 text-ink-soft leading-relaxed">{step.description}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
