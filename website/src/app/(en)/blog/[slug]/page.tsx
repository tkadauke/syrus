import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { Nav } from "../../../../../components/nav";
import { Footer } from "../../../../../components/footer";
import { BlogPostPage } from "../../../../../components/blog-post";
import { blogStaticParams, findPost } from "../../../../../lib/blog";

export const dynamic = "force-static";
export const dynamicParams = false;

type PageProps = { params: Promise<{ slug: string }> };

export function generateStaticParams() {
  return blogStaticParams();
}

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { slug } = await params;
  const post = findPost(slug);
  if (!post) return {};

  return {
    title: post.title,
    description: post.description,
    alternates: { canonical: post.href },
  };
}

export default async function BlogPostRoute({ params }: PageProps) {
  const { slug } = await params;
  const post = findPost(slug);
  if (!post) notFound();

  return (
    <>
      <Nav locale="en" />
      <main id="main">
        <BlogPostPage post={post} />
      </main>
      <Footer locale="en" />
    </>
  );
}
