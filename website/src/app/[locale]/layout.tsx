import { notFound } from "next/navigation";
import { SiteLayout, siteMetadata, siteViewport } from "@/components/site-layout";
import { isLocale, isPublishedLocale, localizedStaticParams } from "@/lib/locales";
import "../globals.css";

export const dynamicParams = false;
export const metadata = siteMetadata;
export const viewport = siteViewport;
export function generateStaticParams() { return localizedStaticParams(); }

export default async function LocalizedLayout({ children, params }: Readonly<{ children: React.ReactNode; params: Promise<{ locale: string }> }>) {
  const { locale } = await params;
  if (!isLocale(locale) || !isPublishedLocale(locale) || locale === "en") notFound();
  return <SiteLayout locale={locale}>{children}</SiteLayout>;
}
