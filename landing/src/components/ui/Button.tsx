"use client";

import { cn } from "@/lib/utils";

interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: "primary" | "secondary" | "outline";
  size?: "sm" | "md" | "lg";
}

export default function Button({
  variant = "primary",
  size = "md",
  className,
  children,
  ...props
}: ButtonProps) {
  return (
    <button
      className={cn(
        "inline-flex items-center justify-center font-semibold rounded-full transition-all duration-300 cursor-pointer",
        "focus:outline-none focus:ring-2 focus:ring-offset-2",
        variant === "primary" &&
          "bg-primary text-white hover:bg-primary-dark focus:ring-primary/50",
        variant === "secondary" &&
          "bg-surface text-white hover:bg-surface-light focus:ring-surface/50",
        variant === "outline" &&
          "border-2 border-gray-200 text-gray-700 hover:border-primary hover:text-black focus:ring-primary/50",
        size === "sm" && "px-4 py-2 text-sm",
        size === "md" && "px-6 py-3 text-base",
        size === "lg" && "px-8 py-4 text-lg",
        className
      )}
      {...props}
    >
      {children}
    </button>
  );
}
