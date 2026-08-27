import { Logo } from "./logo";
import { site } from "../lib/site";

type FooterLink = { label: string; href: string; external?: boolean };

const cols: { title: string; links: FooterLink[] }[] = [
  {
    title: "Product",
    links: [
      { label: "How it works", href: "/#how" },
      { label: "Why Syrus", href: "/#features" },
      { label: "Entry points", href: "/#entry-points" },
      { label: "Plugins", href: "/plugins" },
    ],
  },
  {
    title: "Get started",
    links: [
      { label: "Download", href: "/download" },
      { label: "Docs", href: "/docs" },
      { label: "GitHub repository", href: site.repositoryUrl, external: true },
      { label: "Request a demo", href: "/#demo" },
    ],
  },
];

export function Footer() {
  const shortSha = site.build.sha.slice(0, 7);
  const year = new Date().getFullYear(); // evaluated at build time (static page)

  return (
    <footer className="relative border-t border-white/8 py-14">
      <div className="wrap">
        <div className="grid gap-10 sm:grid-cols-2 lg:grid-cols-4">
          <div className="lg:col-span-2">
            <Logo />
            <p className="mt-4 max-w-xs text-[0.9rem] leading-relaxed text-cream-dim">
              From written intent to reviewed pull requests — with your git
              workflow, your reviews, and your final say kept fully intact.
            </p>
            <p className="mt-4 font-serif text-[0.92rem] italic text-cream-faint">
              {site.tagline}
            </p>
          </div>

          {cols.map((c) => (
            <nav key={c.title} aria-label={c.title}>
              <h3 className="font-mono text-[0.72rem] uppercase tracking-[0.16em] text-cream-faint">
                {c.title}
              </h3>
              <ul className="mt-4 grid gap-2.5">
                {c.links.map((l) => (
                  <li key={l.label}>
                    <a
                      href={l.href}
                      {...(l.external
                        ? { target: "_blank", rel: "noreferrer" }
                        : {})}
                      className="text-[0.9rem] text-cream-dim transition-colors hover:text-cream"
                    >
                      {l.label}
                    </a>
                  </li>
                ))}
              </ul>
            </nav>
          ))}
        </div>

        <div className="mt-12 flex flex-col items-center gap-4 border-t border-white/6 pt-6 sm:flex-row sm:justify-between">
          <div className="flex flex-wrap items-center justify-center gap-x-4 gap-y-1 text-[0.82rem] text-cream-faint">
            <span>© {year} Syrus · {site.domain}</span>
          </div>
          <span className="font-mono text-[0.72rem] text-cream-faint">
            build {shortSha}
          </span>
        </div>
      </div>
    </footer>
  );
}
