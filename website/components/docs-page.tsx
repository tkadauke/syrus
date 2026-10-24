import { allDocs, type DocPage } from "../lib/docs"
import type { Locale } from "../lib/locales"
import { chromeFor } from "../lib/chrome"

export function DocsPage({ doc, locale }: { doc: DocPage; locale: Locale }) {
  const docs = allDocs()
  const copy = chromeFor(locale).docs

  return (
    <div className="wrap grid gap-10 pt-28 pb-20 lg:grid-cols-[17rem_minmax(0,1fr)]">
      <aside className="lg:sticky lg:top-24 lg:self-start">
        <a href="/docs" className="font-mono text-[0.72rem] uppercase tracking-[0.16em] text-cream-faint transition-colors hover:text-cream">
          {copy.home}
        </a>
        <nav aria-label={copy.navigationLabel} className="mt-5 grid gap-1">
          {docs.map((item) => (
            <a
              key={item.href}
              href={item.href}
              aria-current={item.href === doc.href ? "page" : undefined}
              className={`rounded-lg px-3 py-2 text-sm transition-colors ${
                item.href === doc.href
                  ? "bg-[color-mix(in_oklab,var(--color-clay)_18%,transparent)] text-cream"
                  : "text-cream-dim hover:bg-[color-mix(in_oklab,var(--color-cream)_6%,transparent)] hover:text-cream"
              }`}
            >
              {item.title}
              {locale === "en" ? null : copy.englishSuffix}
            </a>
          ))}
        </nav>
      </aside>

      <article className="min-w-0">
        <div className="mb-8 border-b border-white/8 pb-7">
          <p className="font-mono text-[0.72rem] uppercase tracking-[0.16em] text-cream-faint">{copy.eyebrow}</p>
          <h1 className="mt-3 text-balance text-4xl font-semibold tracking-[-0.02em] text-cream sm:text-5xl">{doc.title}</h1>
          {doc.description ? <p className="mt-4 max-w-2xl text-pretty text-lg leading-relaxed text-cream-dim">{doc.description}</p> : null}
        </div>
        <div className="doc-prose" dangerouslySetInnerHTML={{ __html: doc.html }} />
      </article>
    </div>
  )
}
