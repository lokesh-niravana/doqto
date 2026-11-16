"use client";

import { useEffect, useRef } from "react";
import Image from "next/image";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { SECTION_IDS, FEATURES } from "@/lib/constants";
import {
  Shield,
  Mic,
  Building2,
  MessageSquare,
  Timer,
  type LucideIcon,
} from "lucide-react";

gsap.registerPlugin(ScrollTrigger);

const ICONS: Record<string, LucideIcon> = {
  Shield,
  Mic,
  Building2,
  MessageSquare,
  Timer,
};

export default function FeaturesSection() {
  const sectionRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (prefersReduced || !sectionRef.current) return;

    const ctx = gsap.context(() => {
      gsap.fromTo(
        ".features-heading",
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
        ".feature-row",
        { y: 40, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.7,
          stagger: 0.1,
          ease: "power3.out",
          scrollTrigger: { trigger: ".feature-list", start: "top 80%" },
        }
      );

      // Parallax drift inside the sticky photo frame
      gsap.fromTo(
        ".feature-img",
        { yPercent: -6, scale: 1.12 },
        {
          yPercent: 6,
          scale: 1.12,
          ease: "none",
          scrollTrigger: {
            trigger: sectionRef.current,
            start: "top bottom",
            end: "bottom top",
            scrub: true,
          },
        }
      );
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} id={SECTION_IDS.features} className="neu-ground py-24 sm:py-32">
      <div className="max-w-7xl mx-auto px-6 sm:px-8">
        <div className="features-heading max-w-2xl mb-16">
          <p className="text-[13px] font-semibold uppercase tracking-[0.08em] text-ink-muted mb-5">
            The platform
          </p>
          <h2 className="font-display text-4xl sm:text-5xl text-ink leading-[1.1]">
            Everything your team needs, <em>nothing it doesn&rsquo;t.</em>
          </h2>
        </div>

        <div className="grid lg:grid-cols-2 gap-10 lg:gap-16 items-start">
          {/* Sticky photo with parallax */}
          <div className="neu relative hidden lg:block lg:sticky lg:top-28 rounded-[2rem] p-3">
            <div className="relative aspect-[3/4] overflow-hidden rounded-[1.5rem]">
              <Image
                src="/images/consult.jpg"
                alt="A physician reviewing a secure Doqto conversation"
                fill
                quality={90}
                className="feature-img object-cover will-change-transform"
                sizes="(min-width: 1024px) 50vw, 100vw"
              />
            </div>
          </div>

          {/* Neumorphic feature cards */}
          <div className="feature-list flex flex-col gap-6">
            {FEATURES.map((feature) => {
              const Icon = ICONS[feature.icon] ?? Shield;
              return (
                <div
                  key={feature.title}
                  className="feature-row neu flex items-start gap-5 rounded-3xl p-6 sm:p-7"
                >
                  <div className="neu-inset shrink-0 w-14 h-14 rounded-full flex items-center justify-center text-primary">
                    <Icon className="w-6 h-6" strokeWidth={2} />
                  </div>
                  <div>
                    <h3 className="text-xl font-semibold text-ink">{feature.title}</h3>
                    <p className="mt-2 text-ink-soft leading-relaxed">{feature.description}</p>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </section>
  );
}
