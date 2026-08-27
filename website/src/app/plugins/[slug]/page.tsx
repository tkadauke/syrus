import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { Nav } from "../../../../components/nav";
import { Footer } from "../../../../components/footer";
import { findPlugin, pluginStaticParams } from "../../../../lib/plugins";

export const dynamic = "force-static";
export const dynamicParams = false;

type PageProps = { params: Promise<{ slug: string }> };

export function generateStaticParams() {
  return pluginStaticParams();
}

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { slug } = await params;
  const plugin = findPlugin(slug);
  if (!plugin) return {};

  return {
    title: `${plugin.displayName} plugin`,
    description: plugin.description || plugin.summary,
    alternates: { canonical: plugin.href },
  };
}

export default async function PluginPage({ params }: PageProps) {
  const { slug } = await params;
  const plugin = findPlugin(slug);
  if (!plugin) notFound();

  return (
    <>
      <Nav />
      <main id="main">
        <article className="wrap pt-28 pb-20">
          <a
            href="/plugins"
            className="font-mono text-[0.72rem] uppercase tracking-[0.16em] text-cream-faint transition-colors hover:text-cream"
          >
            Plugins
          </a>
          <header className="mt-5 border-b border-white/8 pb-8">
            <div className="flex flex-col gap-5 sm:flex-row sm:items-start">
              <span className="plugin-icon-tile h-16 w-16 rounded-2xl">
                <img
                  src={plugin.iconUrl}
                  alt=""
                  aria-hidden="true"
                  className="h-full w-full object-contain"
                />
              </span>
              <div className="min-w-0">
                <p className="font-mono text-[0.72rem] uppercase tracking-[0.16em] text-cream-faint">
                  {plugin.category} plugin
                </p>
                <h1 className="mt-3 text-balance text-4xl font-semibold tracking-[-0.02em] text-cream sm:text-5xl">
                  {plugin.displayName}
                </h1>
                {plugin.description ? (
                  <p className="mt-4 max-w-3xl whitespace-pre-line text-pretty text-lg leading-relaxed text-cream-dim">
                    {plugin.description}
                  </p>
                ) : null}
                <div className="mt-5 flex flex-wrap gap-3 text-sm text-cream-dim">
                  <span className="rounded-full bg-white/8 px-3 py-1 font-mono">
                    {plugin.name}
                  </span>
                  <a
                    href={plugin.sourceUrl}
                    target="_blank"
                    rel="noreferrer"
                    className="rounded-full border border-white/12 px-3 py-1 transition-colors hover:border-clay-bright hover:text-cream"
                  >
                    Source
                  </a>
                </div>
              </div>
            </div>
          </header>
          <div
            className="doc-prose mt-8"
            dangerouslySetInnerHTML={{ __html: plugin.html }}
          />
        </article>
      </main>
      <Footer />
    </>
  );
}
