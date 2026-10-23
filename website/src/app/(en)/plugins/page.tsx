import type { Metadata } from "next";
import { localizedMetadata } from "@/lib/metadata";
import { Nav } from "@/components/nav";
import { Footer } from "@/components/footer";
import { PluginDirectory } from "@/components/plugin-directory";
import { pluginDirectoryEntries } from "@/lib/plugins";

export const metadata: Metadata = localizedMetadata({
  locale: "en", pathname: "/plugins", title: "Plugins",
  description: "Directory of Syrus plugins, extension points, and bundled capabilities.",
});

export default function PluginsPage() {
  return (
    <>
      <Nav locale="en" />
      <main id="main">
        <PluginDirectory plugins={pluginDirectoryEntries()} locale="en" />
      </main>
      <Footer locale="en" />
    </>
  );
}
