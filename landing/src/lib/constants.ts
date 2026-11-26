export const COLORS = {
  primary: "#35878F",
  primaryDark: "#1E2A5A",
  background: "#000000",
  surface: "#18181F",
  surfaceLight: "#2A2A35",
  dark: "#0A0A0A",
  lightBg: "#F8F9FA",
  white: "#FFFFFF",
  textSecondary: "#6B7280",
  success: "#34C759",
  error: "#FF3B30",
} as const;

export const SECTION_IDS = {
  hero: "hero",
  problem: "problem",
  features: "features",
  security: "security",
  howItWorks: "how-it-works",
  audience: "who-its-for",
  testimonials: "testimonials",
  cta: "join-waitlist",
} as const;

export const NAV_LINKS = [
  { label: "Features", href: `#${SECTION_IDS.features}` },
  { label: "Security", href: `#${SECTION_IDS.security}` },
  { label: "How It Works", href: `#${SECTION_IDS.howItWorks}` },
] as const;

export const STATS = [
  { value: 150, prefix: "$", suffix: "B+", label: "Lost to no-shows annually" },
  { value: 22, prefix: "", suffix: " hrs", label: "Avg patient message response time" },
  { value: 725, prefix: "", suffix: "+", label: "Healthcare data breaches in 2023" },
] as const;

export const FEATURES = [
  {
    title: "Encryption",
    description:
      "TLS in transit and AES-256-GCM field-level encryption at rest, with a separate key for every organisation.",
    icon: "Shield",
  },
  {
    title: "Voice Messaging",
    description:
      "Send encrypted voice messages with waveform visualization and automatic speech-to-text transcription.",
    icon: "Mic",
  },
  {
    title: "Organization Management",
    description:
      "Create departments, assign roles, manage invite codes. Built for clinics, hospitals, and health networks.",
    icon: "Building2",
  },
  {
    title: "Real-Time Messaging",
    description:
      "Instant delivery with read receipts, typing indicators, and online presence — all over encrypted channels.",
    icon: "MessageSquare",
  },
  {
    title: "Disappearing Messages",
    description:
      "Configurable auto-delete for sensitive discussions. Set retention policies that match your compliance requirements.",
    icon: "Timer",
  },
] as const;

export const SECURITY_FEATURES = [
  {
    title: "AES-256-GCM Encryption",
    description:
      "Military-grade field-level encryption. 96-bit GCM nonce with authenticated encryption for every message.",
    icon: "Lock",
  },
  {
    title: "TLS 1.2+ Transport",
    description:
      "All data in transit protected with TLS 1.2 or higher. HSTS enforced across all endpoints.",
    icon: "Globe",
  },
  {
    title: "Audited Access",
    description:
      "Message content is limited to a conversation's participants. Any administrative access needs approval and is written to an audit log.",
    icon: "EyeOff",
  },
  {
    title: "Audit Logging",
    description:
      "Comprehensive tamper-resistant audit trails. 6+ year retention for full HIPAA compliance.",
    icon: "FileText",
  },
  {
    title: "Device Security",
    description:
      "Root and jailbreak detection blocks compromised devices. PHI never touches an insecure environment.",
    icon: "Smartphone",
  },
  {
    title: "BAA Available",
    description:
      "Business Associate Agreements ready for your organization. Full HIPAA compliance documentation included.",
    icon: "FileCheck",
  },
] as const;

export const STEPS = [
  {
    step: 1,
    title: "Sign Up Securely",
    description:
      "Phone OTP verification — no passwords to remember or leak. Your identity, verified in seconds.",
  },
  {
    step: 2,
    title: "Create or Join Organization",
    description:
      "Set up your clinic with invite codes and departments. Or join an existing organization instantly.",
  },
  {
    step: 3,
    title: "Start Communicating",
    description:
      "Send encrypted messages and voice notes. Everything HIPAA-compliant from message one.",
  },
] as const;

export const AUDIENCES = [
  { title: "Private Clinics", size: "10-25 staff", icon: "Stethoscope" },
  { title: "Medical Practices", size: "26-100 staff", icon: "Hospital" },
  { title: "Hospitals", size: "101-500 staff", icon: "Building" },
  { title: "Health Networks", size: "500+ staff", icon: "Network" },
  { title: "Mental Health", size: "All sizes", icon: "Heart" },
  { title: "Specialty Practices", size: "All sizes", icon: "Microscope" },
] as const;

export const SPECIALTIES = [
  "Internal Medicine",
  "Family Practice",
  "Cardiology",
  "Pediatrics",
  "Oncology",
  "Emergency Medicine",
  "Psychiatry",
  "Dermatology",
  "Radiology",
  "Orthopedics",
  "Neurology",
  "OB-GYN",
  "Urgent Care",
  "Nursing Teams",
  "Behavioral Health",
  "Home Health",
] as const;

export const TESTIMONIALS = [
  {
    name: "Dr. Sarah Chen",
    role: "Chief of Internal Medicine",
    org: "Pacific Health Group",
    quote:
      "Doqto replaced three different tools we were using. Secure messaging, voice notes, and transcription in one place saves our team hours every week.",
    initials: "SC",
  },
  {
    name: "Dr. Marcus Webb",
    role: "Practice Owner",
    org: "Webb Family Medicine",
    quote:
      "Finally, a messaging platform that takes HIPAA seriously without making it painful. Our staff actually enjoys using it.",
    initials: "MW",
  },
  {
    name: "Dr. Priya Patel",
    role: "Director of Nursing",
    org: "Meridian Hospital System",
    quote:
      "The voice messaging with auto-transcription has been a game changer for our on-call nurses. Fast, secure, and searchable.",
    initials: "PP",
  },
] as const;
