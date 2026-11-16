"use client";

import { useEffect, useRef } from "react";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { SECTION_IDS, STATS } from "@/lib/constants";
import { useCountUp } from "@/hooks/useCountUp";

gsap.registerPlugin(ScrollTrigger);

function StatColumn({
  value,
  prefix,
  suffix,
  label,
  first,
}: {
  value: number;
  prefix: string;
  suffix: string;
  label: string;
  first: boolean;
}) {
  const { ref, count } = useCountUp(value);

  return (
    <div
      className={
        first
          ? "problem-stat py-8 lg:py-0 lg:pr-12"
          : "problem-stat py-8 lg:py-0 lg:pl-12 border-t lg:border-t-0 lg:border-l border-line"
      }
    >
      <div
        ref={ref as React.RefObject<HTMLDivElement>}
        className="font-display text-5xl sm:text-6xl text-ink"
      >
        {prefix}
        {count}
        {suffix}
      </div>
      <p className="mt-3 text-ink-soft leading-relaxed max-w-xs">{label}</p>
    </div>
  );
}

export default function ProblemSection() {
  const sectionRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (prefersReduced || !sectionRef.current) return;

    const ctx = gsap.context(() => {
      gsap.fromTo(
        ".problem-reveal",
        { y: 50, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.9,
          stagger: 0.12,
          ease: "power3.out",
          scrollTrigger: { trigger: sectionRef.current, start: "top 75%" },
        }
      );
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} id={SECTION_IDS.problem} className="py-28 sm:py-36">
      <div className="max-w-5xl mx-auto px-6 sm:px-8">
        <p className="problem-reveal text-sm uppercase tracking-[0.2em] text-ink-soft text-center mb-6">
          The problem
        </p>
        <h2 className="problem-reveal font-display text-4xl sm:text-5xl lg:text-6xl text-ink text-center leading-[1.08]">
          Healthcare runs on messages.
          <br />
          Most of them are <em>unprotected.</em>
        </h2>
        <p className="problem-reveal mt-6 text-lg text-ink-soft text-center max-w-2xl mx-auto leading-relaxed">
          Texts, pagers, and consumer apps leak PHI, slow down care, and put
          providers at risk — every single day.
        </p>

        <div className="problem-reveal mt-16 flex flex-col lg:flex-row lg:justify-center">
          {STATS.map((stat, i) => (
            <StatColumn
              key={stat.label}
              value={stat.value}
              prefix={stat.prefix}
              suffix={stat.suffix}
              label={stat.label}
              first={i === 0}
            />
          ))}
        </div>
      </div>
    </section>
  );
}
