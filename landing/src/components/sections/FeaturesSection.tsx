"use client";

import { useEffect, useRef } from "react";
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
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} id={SECTION_IDS.features} className="py-20 sm:py-24 bg-subtle">
      <div className="max-w-7xl mx-auto px-6 sm:px-8">
        <div className="features-heading max-w-2xl mx-auto text-center mb-12">
          <p className="text-[13px] font-semibold uppercase tracking-[0.08em] text-ink-muted mb-5">
            The platform
          </p>
          <h2 className="font-display text-4xl sm:text-5xl text-ink leading-[1.1]">
            Everything your team needs, <em>nothing it doesn&rsquo;t.</em>
          </h2>
        </div>

        {/* Benefit cards: tinted panel, round icon disc, centred copy */}
        <div className="feature-list grid sm:grid-cols-2 lg:grid-cols-3 gap-6">
          {FEATURES.map((feature) => {
            const Icon = ICONS[feature.icon] ?? Shield;
            return (
              <div
                key={feature.title}
                className="feature-row flex flex-col items-center text-center rounded-3xl bg-tint p-8 transition-colors duration-300 hover:bg-tint-strong"
              >
                <div className="w-14 h-14 rounded-full bg-primary text-white flex items-center justify-center mb-5">
                  <Icon className="w-6.5 h-6.5" strokeWidth={2} />
                </div>
                <h3 className="text-2xl font-semibold leading-tight text-ink">
                  {feature.title}
                </h3>
                <p className="mt-3 text-ink-soft leading-relaxed">
                  {feature.description}
                </p>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
}
