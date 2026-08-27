"use client";

import { useMemo, useState } from "react";
import type { PluginDirectoryEntry } from "../lib/plugins";

export function PluginDirectory({ plugins }: { plugins: PluginDirectoryEntry[] }) {
  const [query, setQuery] = useState("");
  const normalizedQuery = query.trim().toLowerCase();
  const visiblePlugins = useMemo(() => {
    if (!normalizedQuery) return plugins;
    return plugins.filter((plugin) => [
      plugin.displayName,
      plugin.name,
      plugin.category,
      plugin.summary,
      plugin.description,
    ].join(" ").toLowerCase().includes(normalizedQuery));
  }, [normalizedQuery, plugins]);

  return (
    <section className="wrap pt-28 pb-20">
      <div className="max-w-3xl">
        <p className="font-mono text-[0.72rem] uppercase tracking-[0.16em] text-cream-faint">
          Extensions
        </p>
        <h1 className="mt-3 text-balance text-4xl font-semibold tracking-[-0.02em] text-cream sm:text-5xl">
          Syrus plugins
        </h1>
        <p className="mt-4 text-pretty text-lg leading-relaxed text-cream-dim">
          Browse the plugin gems bundled with Syrus. Each plugin documents the
          extension points it owns, when to enable it, and how it fits into a
          Syrus installation.
        </p>
      </div>

      <div className="mt-8 max-w-2xl">
        <label htmlFor="plugin-search" className="sr-only">Search plugins</label>
        <input
          id="plugin-search"
          type="search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Search plugins by name, category, or capability"
          className="w-full rounded-xl border border-white/12 bg-white/6 px-4 py-3 text-base text-cream outline-none transition-colors placeholder:text-cream-faint focus:border-clay-bright"
        />
      </div>

      <div className="mt-8 grid gap-4 md:grid-cols-2">
        {visiblePlugins.map((plugin) => (
          <a
            key={plugin.slug}
            href={plugin.href}
            className="card group block p-5 transition-colors hover:border-clay/40"
          >
            <div className="flex items-start gap-4">
              <span className="plugin-icon-tile h-11 w-11 shrink-0 rounded-lg">
                <img
                  src={plugin.iconUrl}
                  alt=""
                  aria-hidden="true"
                  className="h-full w-full object-contain"
                />
              </span>
              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-2">
                  <h2 className="text-lg font-semibold text-cream group-hover:text-clay-bright">
                    {plugin.displayName}
                  </h2>
                  <span className="rounded-full bg-white/8 px-2.5 py-1 font-mono text-[0.72rem] text-cream-dim">
                    {plugin.category}
                  </span>
                </div>
                <p className="mt-2 line-clamp-4 text-sm leading-6 text-cream-dim">
                  {plugin.description || plugin.summary}
                </p>
              </div>
            </div>
          </a>
        ))}
      </div>

      {visiblePlugins.length === 0 ? (
        <div className="mt-8 rounded-xl border border-dashed border-white/14 p-8 text-cream-dim">
          No plugins match that search.
        </div>
      ) : null}
    </section>
  );
}
