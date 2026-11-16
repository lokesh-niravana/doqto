import Navbar from "@/components/layout/Navbar";
import HeroSection from "@/components/sections/HeroSection";
import ProblemSection from "@/components/sections/ProblemSection";
import FeaturesSection from "@/components/sections/FeaturesSection";
import SecuritySection from "@/components/sections/SecuritySection";
import HowItWorksSection from "@/components/sections/HowItWorksSection";
import AudienceSection from "@/components/sections/AudienceSection";
import TestimonialsSection from "@/components/sections/TestimonialsSection";
import FinalCTASection from "@/components/sections/FinalCTASection";
import Footer from "@/components/layout/Footer";
import ParticleField from "@/components/effects/ParticleField";

export default function Home() {
  return (
    <>
      <ParticleField />
      <Navbar />
      <main className="relative z-10">
        <HeroSection />
        <ProblemSection />
        <FeaturesSection />
        <SecuritySection />
        <HowItWorksSection />
        <AudienceSection />
        <TestimonialsSection />
        <FinalCTASection />
      </main>
      <Footer />
    </>
  );
}
