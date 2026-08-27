"use client";

import { useEffect, useState } from "react";
import { Logo } from "./logo";
import { ButtonLink } from "./button";
import { DownloadButton } from "./download-cta";
import { site } from "../lib/site";

const links = [
  { href: "/#how", label: "How it works" },
  { href: "/#features", label: "Why Syrus" },
  { href: "/#entry-points", label: "Entry points" },
  { href: "/plugins", label: "Plugins" },
  { href: "/docs", label: "Docs" },
];

export function Nav() {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 12);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header className="fixed inset-x-0 top-0 z-50">
      <div
        className={`transition-colors duration-300 ${
          scrolled
            ? "border-b border-[color-mix(in_oklab,var(--color-cream)_8%,transparent)] bg-[color-mix(in_oklab,var(--color-ink)_78%,transparent)] backdrop-blur-xl"
            : "border-b border-transparent"
        }`}
      >
        <nav className="wrap flex h-16 items-center justify-between">
          <a href="/" aria-label="Syrus home">
            <Logo />
          </a>

          <div className="hidden items-center gap-1 md:flex">
            {links.map((l) => (
              <a
                key={l.href}
                href={l.href}
                className="rounded-full px-3.5 py-2 text-sm text-cream-dim transition-colors hover:text-cream"
              >
                {l.label}
              </a>
            ))}
          </div>

          <div className="flex items-center gap-2">
            <a
              href={site.repositoryUrl}
              target="_blank"
              rel="noreferrer"
              className="hidden rounded-full px-3.5 py-2 text-sm font-medium text-cream-dim transition-colors hover:bg-[color-mix(in_oklab,var(--color-cream)_6%,transparent)] hover:text-cream sm:inline-flex"
            >
              GitHub
            </a>
            <span className="hidden sm:inline-flex">
              <ButtonLink href="/#demo" variant="ghost" size="md">
                Request a demo
              </ButtonLink>
            </span>
            <DownloadButton />
          </div>
        </nav>
      </div>
    </header>
  );
}
