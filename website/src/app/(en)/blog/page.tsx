import type { Metadata } from "next";
import { Nav } from "../../../../components/nav";
import { Footer } from "../../../../components/footer";
import { allPosts, formatPostDate } from "../../../../lib/blog";

export const metadata: Metadata = {
  title: "Blog",
  description:
    "Notes from building Syrus: AI-native UX experiments, engineering deep dives, and what a fleet of coding agents teaches you.",
  alternates: { types: { "application/rss+xml": "/blog/feed.xml" } },
};

export default function BlogIndexPage() {
  const posts = allPosts();

  return (
    <>
      <Nav locale="en" />
      <main id="main">
        <div className="wrap pt-28 pb-20">
          <div className="mx-auto max-w-3xl">
            <div className="mb-10 border-b border-white/8 pb-7">
              <p className="font-mono text-[0.72rem] uppercase tracking-[0.16em] text-cream-faint">
                Blog
              </p>
              <h1 className="mt-3 text-balance text-4xl font-semibold tracking-[-0.02em] text-cream sm:text-5xl">
                Notes from building Syrus
              </h1>
              <p className="mt-4 max-w-2xl text-pretty text-lg leading-relaxed text-cream-dim">
                AI-native UX experiments, engineering deep dives, and what a
                fleet of coding agents teaches you.
              </p>
            </div>

            <div className="grid gap-2">
              {posts.map((post) => (
                <a
                  key={post.href}
                  href={post.href}
                  className="group rounded-xl px-4 py-5 transition-colors hover:bg-[color-mix(in_oklab,var(--color-cream)_6%,transparent)]"
                >
                  {post.date ? (
                    <p className="font-mono text-[0.72rem] uppercase tracking-[0.16em] text-cream-faint">
                      {formatPostDate(post.date)}
                    </p>
                  ) : null}
                  <h2 className="mt-2 text-2xl font-semibold tracking-[-0.01em] text-cream group-hover:underline">
                    {post.title}
                  </h2>
                  {post.description ? (
                    <p className="mt-2 leading-relaxed text-cream-dim">
                      {post.description}
                    </p>
                  ) : null}
                </a>
              ))}
            </div>
          </div>
        </div>
      </main>
      <Footer locale="en" />
    </>
  );
}
