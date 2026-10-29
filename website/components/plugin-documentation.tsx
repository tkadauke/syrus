import type { PluginDocument } from "../lib/plugins"

export function PluginDocumentation({ documents }: { documents: PluginDocument[] }) {
  return (
    <>
      {documents.length > 1 ? (
        <nav aria-label="Plugin documentation" className="mt-8 rounded-2xl border border-white/10 bg-white/[0.03] p-5">
          <p className="font-mono text-[0.72rem] uppercase tracking-[0.16em] text-cream-faint">On this page</p>
          <ul className="mt-3 flex flex-wrap gap-x-5 gap-y-2">
            {documents.map((document) => (
              <li key={document.slug}>
                <a className="text-sm text-cream-dim transition-colors hover:text-cream" href={`#doc-${document.slug}`}>
                  {document.title}
                </a>
              </li>
            ))}
          </ul>
        </nav>
      ) : null}
      {documents.map((document, index) => (
        <section
          id={`doc-${document.slug}`}
          key={document.slug}
          className={index === 0 ? "doc-prose mt-8 scroll-mt-24" : "doc-prose mt-14 scroll-mt-24 border-t border-white/8 pt-10"}
          aria-label={document.title}
          dangerouslySetInnerHTML={{ __html: document.html }}
        />
      ))}
    </>
  )
}
