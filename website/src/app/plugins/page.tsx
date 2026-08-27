import type { Metadata } from "next";
import { Nav } from "../../../components/nav";
import { Footer } from "../../../components/footer";
import { PluginDirectory } from "../../../components/plugin-directory";
import { pluginDirectoryEntries } from "../../../lib/plugins";

export const metadata: Metadata = {
  title: "Plugins",
  description: "Directory of Syrus plugins, extension points, and bundled capabilities.",
  alternates: { canonical: "/plugins" },
};

export default function PluginsPage() {
  return (
    <>
      <Nav />
      <main id="main">
        <PluginDirectory plugins={pluginDirectoryEntries()} />
      </main>
      <Footer />
    </>
  );
}
