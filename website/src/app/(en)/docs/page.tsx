import type { Metadata } from "next";
import { localizedMetadata } from "@/lib/metadata";
import { Nav } from "@/components/nav";
import { Footer } from "@/components/footer";
import { DocsPage } from "@/components/docs-page";
import { findDoc } from "@/lib/docs";

export const metadata: Metadata = localizedMetadata({
  locale: "en", pathname: "/docs", title: "Docs",
  description: "Syrus product docs, setup paths, operations, and troubleshooting.",
});

export default function DocsIndexPage() {
  const doc = findDoc([]);
  if (!doc) throw new Error("Missing docs index");

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
