import fs from "node:fs";
import path from "node:path";
import { Nav } from "../../components/nav";
import { Hero } from "../../components/hero";
import { TeamWorkflow } from "../../components/team-workflow";
import { Features } from "../../components/features";
import { EntryPoints } from "../../components/entry-points";
import { Demo } from "../../components/demo";
import { Footer } from "../../components/footer";

// Resolve product screenshots on the server so the hero renders the real image
// (or the built-in mock) deterministically — no client hydration race. Drop
// public/product-screenshot.<ext> (and optionally -mobile) and redeploy.
function publicAsset(base: string): string | null {
  for (const ext of ["png", "jpg", "jpeg", "webp", "avif"]) {
    if (fs.existsSync(path.join(process.cwd(), "public", `${base}.${ext}`))) {
      return `/${base}.${ext}`;
    }
  }
  return null;
}
const desktopSrc = publicAsset("product-screenshot");
const mobileSrc = publicAsset("product-screenshot-mobile");

export default function Home() {
  return (
    <>
      <Nav />
      <main id="main">
        <Hero desktopSrc={desktopSrc} mobileSrc={mobileSrc} />
        <TeamWorkflow />
        <Features />
        <EntryPoints />
        <Demo />
      </main>
      <Footer />
    </>
  );
}
