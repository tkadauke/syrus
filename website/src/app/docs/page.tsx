import type { Metadata } from "next";
import { Nav } from "../../../components/nav";
import { Footer } from "../../../components/footer";
import { DocsPage } from "../../../components/docs-page";
import { findDoc } from "../../../lib/docs";

export const metadata: Metadata = {
  title: "Docs",
  description: "Syrus product docs, setup paths, operations, and troubleshooting.",
};

export default function DocsIndexPage() {
  const doc = findDoc([]);
  if (!doc) throw new Error("Missing docs index");

  return (
    <>
      <Nav />
      <main id="main">
        <DocsPage doc={doc} />
      </main>
      <Footer />
    </>
  );
}
