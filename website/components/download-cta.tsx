"use client";

import { useEffect, useState } from "react";
import { ButtonLink } from "./button";
import { AppleIcon, DownloadIcon } from "./icons";
import { downloadFor } from "../lib/release";

export type OS = "mac" | "mobile" | "other";

/** Detect the visitor's OS on the client (null until mounted). */
export function useDetectedOS(): OS | null {
  const [os, setOs] = useState<OS | null>(null);
  useEffect(() => {
    const ua = navigator.userAgent || "";
    setOs(
      /Android|iPhone|iPad|iPod/i.test(ua)
        ? "mobile"
        : /Macintosh|Mac OS X/i.test(ua)
            ? "mac"
            : "other",
    );
  }, []);
  return os;
}

function target(os: OS | null) {
  // Direct-download buttons point at GitHub's stable latest-release permalinks
  // (the asset is served with an attachment disposition, so it downloads).
  if (os === "mac")
    return {
      href: downloadFor("mac")!.url,
      label: "Download for Mac",
      Icon: AppleIcon,
    };
  // null (pre-detect), mobile, or unknown → send to the full options page.
  return { href: "/download", label: "Download", Icon: DownloadIcon };
}

/** Compact OS-aware download button (used in the nav) — OS icon + "Download". */
export function DownloadButton() {
  const os = useDetectedOS();
  const { href, label, Icon } = target(os);
  return (
    <ButtonLink href={href} variant="primary" size="md" aria-label={label}>
      <Icon className="size-[18px]" />
      <span className="hidden sm:inline">Download</span>
    </ButtonLink>
  );
}

/** Full hero/section CTA: OS-aware primary button + "other options" link. */
export function DownloadCTA({ size = "lg" }: { size?: "md" | "lg" }) {
  const os = useDetectedOS();
  const { href, label, Icon } = target(os);
  const specific = os === "mac";

  return (
    <div className="flex flex-col items-stretch gap-1.5 sm:items-start">
      <ButtonLink
        href={href}
        variant="primary"
        size={size}
        className="w-full justify-center sm:w-auto"
      >
        <Icon className="size-5" />
        {label}
      </ButtonLink>
      {/* Reserve the line so detection doesn't shift layout. */}
      <div className="h-[1.15rem] text-center sm:text-left">
        {specific ? (
          <a
            href="/download"
            className="text-[0.8rem] text-cream-faint underline underline-offset-2 transition-colors hover:text-cream"
          >
            Other download options
          </a>
        ) : null}
      </div>
    </div>
  );
}
