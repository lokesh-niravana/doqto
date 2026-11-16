"use client";

import { useEffect, useRef } from "react";
import Image from "next/image";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { SECTION_IDS } from "@/lib/constants";
import { ArrowRight, Mic, ShieldCheck, Users } from "lucide-react";

gsap.registerPlugin(ScrollTrigger);

const HERO_STATS = [
  { value: "AES-256", label: "End-to-end encrypted" },
  { value: "HIPAA", label: "Compliant from day one" },
  { value: "BAA", label: "Ready for your org" },
] as const;

// Bar heights for the voice-note waveform in the floating chat card.
const WAVEFORM = [8, 16, 10, 20, 12, 16, 8, 18, 10, 14, 8, 16] as const;

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
        { yPercent: -4, scale: 1.1 },
        {
          yPercent: 4,
          scale: 1.1,
          ease: "none",
          scrollTrigger: {
            trigger: sectionRef.current,
            start: "top top",
            end: "bottom top",
            scrub: true,
          },
        }
      );

      // Floating glass cards move against the photo for depth
      gsap.to(".hero-float", {
        yPercent: -30,
        ease: "none",
        scrollTrigger: {
          trigger: sectionRef.current,
          start: "top top",
          end: "bottom top",
          scrub: true,
        },
      });
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  const scrollToWaitlist = () => {
    const lenis = (window as unknown as { lenis?: { scrollTo: (target: string, options?: Record<string, unknown>) => void } }).lenis;
    if (lenis) lenis.scrollTo(`#${SECTION_IDS.cta}`, { offset: -40, duration: 1.4 });
    else document.getElementById(SECTION_IDS.cta)?.scrollIntoView({ behavior: "smooth" });
  };

  return (
    <section ref={sectionRef} id={SECTION_IDS.hero} className="relative overflow-hidden pt-32 sm:pt-40 pb-20">
      {/* Soft colour behind the glass */}
      <div className="orb w-[30rem] h-[30rem] bg-primary/20 -top-32 -right-32" />
      <div className="orb w-[22rem] h-[22rem] bg-sky/40 top-1/2 -left-40 [animation-delay:-6s]" />

      <div className="relative max-w-7xl mx-auto px-6 sm:px-8">
        <div className="grid lg:grid-cols-2 gap-14 lg:gap-16 items-center">
          <div>
            <div className="hero-reveal glass inline-flex items-center gap-2 rounded-full px-4 py-2 text-[13px] font-semibold uppercase tracking-[0.08em] text-primary-dark mb-7">
              <ShieldCheck className="w-4 h-4" strokeWidth={2.2} />
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
                className="group inline-flex items-center gap-2.5 rounded-full bg-primary px-8 py-4 text-base font-semibold text-white shadow-[0_14px_34px_-10px_rgba(29,106,229,0.65)] transition-all duration-300 hover:bg-primary-dark hover:-translate-y-0.5 cursor-pointer"
              >
                Join the waitlist
                <ArrowRight className="w-5 h-5 transition-transform duration-300 group-hover:translate-x-1" />
              </button>
              <span className="text-base text-ink-muted">Free for verified physicians</span>
            </div>
          </div>

          {/* Photo with floating glass cards */}
          <div className="hero-reveal relative">
            <div className="relative aspect-square overflow-hidden rounded-[2rem] shadow-[0_40px_80px_-30px_rgba(11,31,71,0.45)]">
              <Image
                src="/images/hero.jpg"
                alt="Two physicians in a modern clinic reviewing a secure conversation"
                fill
                priority
                quality={90}
                className="hero-img object-cover object-right will-change-transform"
                sizes="(min-width: 1024px) 50vw, 100vw"
              />
            </div>

            <div className="hero-float glass absolute right-4 top-6 sm:-right-5 flex items-center gap-2.5 rounded-full px-4 py-2.5 text-sm font-semibold text-ink">
              <span className="flex items-center justify-center w-7 h-7 rounded-full bg-primary text-white">
                <ShieldCheck className="w-4 h-4" strokeWidth={2.2} />
              </span>
              Verified physicians
            </div>

            <div
              className="hero-float glass absolute left-4 -bottom-8 sm:-left-8 w-[17.5rem] rounded-3xl p-5 flex flex-col gap-3"
              aria-hidden="true"
            >
              <div className="flex items-center gap-3">
                <div className="flex items-center justify-center w-10 h-10 rounded-full bg-primary text-white">
                  <Users className="w-5 h-5" strokeWidth={2} />
                </div>
                <div>
                  <div className="text-[15px] font-semibold text-ink leading-tight">Cardiology on-call</div>
                  <div className="text-[13px] text-ink-soft">Group chat</div>
                </div>
              </div>
              <div className="self-start rounded-2xl bg-white/80 px-3.5 py-2.5 text-sm text-ink-soft">
                Can someone look at the echo?
              </div>
              <div className="self-end rounded-2xl bg-primary px-3.5 py-2.5 text-white flex items-center gap-2.5">
                <Mic className="w-4 h-4 shrink-0" strokeWidth={2} />
                <span className="flex items-center gap-[3px]">
                  {WAVEFORM.map((h, i) => (
                    <span key={i} className="w-[3px] rounded-full bg-white" style={{ height: h }} />
                  ))}
                </span>
              </div>
            </div>
          </div>
        </div>

        <div className="hero-reveal mt-20 grid sm:grid-cols-3 gap-5">
          {HERO_STATS.map((stat) => (
            <div key={stat.value} className="glass rounded-3xl px-7 py-6">
              <div className="font-display text-2xl text-ink">{stat.value}</div>
              <div className="mt-1 text-sm text-ink-soft">{stat.label}</div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
