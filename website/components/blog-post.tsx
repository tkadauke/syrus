import { formatPostDate, type BlogPost } from "../lib/blog";

export function BlogPostPage({ post }: { post: BlogPost }) {
  return (
    <div className="wrap pt-28 pb-20">
      <article className="mx-auto min-w-0 max-w-3xl">
        <div className="mb-8 border-b border-white/8 pb-7">
          <p className="font-mono text-[0.72rem] uppercase tracking-[0.16em] text-cream-faint">
            <a href="/blog" className="transition-colors hover:text-cream">
              Blog
            </a>
            {post.date ? <span> · {formatPostDate(post.date)}</span> : null}
          </p>
          <h1 className="mt-3 text-balance text-4xl font-semibold tracking-[-0.02em] text-cream sm:text-5xl">
            {post.title}
          </h1>
          {post.description ? (
            <p className="mt-4 max-w-2xl text-pretty text-lg leading-relaxed text-cream-dim">
              {post.description}
            </p>
          ) : null}
        </div>
        <div
          className="doc-prose"
          dangerouslySetInnerHTML={{ __html: post.html }}
        />
        <p className="mt-12 border-t border-white/8 pt-6">
          <a
            href="/blog"
            className="font-mono text-[0.72rem] uppercase tracking-[0.16em] text-cream-faint transition-colors hover:text-cream"
          >
            ← All posts
          </a>
        </p>
      </article>
    </div>
  );
}
