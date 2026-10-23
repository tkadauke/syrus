import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { Nav } from "@/components/nav";
import { Footer } from "@/components/footer";
import { DocsPage } from "@/components/docs-page";
import { docsStaticParams, findDoc } from "@/lib/docs";

export const dynamic = "force-static";
export const dynamicParams = false;

type PageProps = { params: Promise<{ slug: string[] }> };

export function generateStaticParams() {
  return docsStaticParams();
}

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { slug } = await params;
  const doc = findDoc(slug);
  if (!doc) return {};

  return {
    title: doc.title,
    description: doc.description,
    alternates: { canonical: doc.href },
  };
}

export default async function DocPage({ params }: PageProps) {
  const { slug } = await params;
  const doc = findDoc(slug);
  if (!doc) notFound();

  return (
    <>
      <Nav locale="en" />
      <main id="main">
        <DocsPage doc={doc} locale="en" />
      </main>
      <Footer locale="en" />
    </>
  );
}
