"use client";

import { useState } from "react";
import { cn } from "@/lib/utils";
import { ArrowRight, Check, Loader2 } from "lucide-react";

interface WaitlistFormProps {
  large?: boolean;
  className?: string;
}

export default function WaitlistForm({
  large = false,
  className,
}: WaitlistFormProps) {
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<"idle" | "loading" | "success" | "error">("idle");
  const [message, setMessage] = useState("");

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!email) return;

    setStatus("loading");
    try {
      const body = JSON.stringify({ email });
      // CloudFront's Lambda OAC requires the payload hash on POST requests.
      const digest = await crypto.subtle.digest(
        "SHA-256",
        new TextEncoder().encode(body)
      );
      const hash = Array.from(new Uint8Array(digest))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");
      const res = await fetch("/api/waitlist", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-amz-content-sha256": hash,
        },
        body,
      });
      const data = await res.json();
      if (data.success) {
        setStatus("success");
        setMessage("You're on the list! We'll be in touch.");
        setEmail("");
      } else {
        setStatus("error");
        setMessage(data.message || "Something went wrong.");
      }
    } catch {
      setStatus("error");
      setMessage("Network error. Please try again.");
    }
  };

  if (status === "success") {
    return (
      <div
        className={cn(
          "flex items-center gap-3 px-6 py-4 rounded-full bg-green-50 border border-green-200",
          className
        )}
      >
        <div className="flex items-center justify-center w-8 h-8 rounded-full bg-green-500 text-white">
          <Check className="w-5 h-5" />
        </div>
        <span className="text-green-800 font-medium">{message}</span>
      </div>
    );
  }

  return (
    <form
      onSubmit={handleSubmit}
      className={cn("flex flex-col sm:flex-row gap-3", className)}
    >
      <div className="relative flex-1">
        <input
          type="email"
          value={email}
          onChange={(e) => {
            setEmail(e.target.value);
            if (status === "error") setStatus("idle");
          }}
          placeholder="Enter your work email"
          required
          className={cn(
            "w-full rounded-full border bg-white text-ink placeholder:text-ink-muted transition-all duration-300",
            "focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary",
            large
              ? "px-7 py-4.5 text-lg border-line"
              : "px-5 py-3.5 text-base border-line",
            status === "error" && "border-red-300 focus:ring-red-200"
          )}
        />
      </div>
      <button
        type="submit"
        disabled={status === "loading"}
        className={cn(
          "inline-flex items-center justify-center gap-2 rounded-full font-medium transition-all duration-300 cursor-pointer",
          "bg-primary text-white hover:bg-primary-dark",
          "disabled:opacity-60 disabled:cursor-not-allowed disabled:hover:translate-y-0",
          "focus:outline-none focus:ring-2 focus:ring-primary/50 focus:ring-offset-2",
          large ? "px-8 py-4.5 text-lg" : "px-6 py-3.5 text-base"
        )}
      >
        {status === "loading" ? (
          <Loader2 className="w-5 h-5 animate-spin" />
        ) : (
          <>
            Join Waitlist
            <ArrowRight className="w-5 h-5" />
          </>
        )}
      </button>
      {status === "error" && (
        <p className="text-red-500 text-sm mt-1 sm:absolute sm:-bottom-6 sm:left-0">
          {message}
        </p>
      )}
    </form>
  );
}
