import { SiteLayout, siteMetadata, siteViewport } from "@/components/site-layout";
import "../globals.css";

export const metadata = siteMetadata;
export const viewport = siteViewport;

export default function EnglishLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <SiteLayout locale="en">{children}</SiteLayout>;
}
