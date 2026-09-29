import type { SVGProps } from "react";

type IconProps = SVGProps<SVGSVGElement>;

const base = {
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.6,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
};

export function AppleIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden {...props}>
      <path d="M16.365 12.68c.02 2.29 2.01 3.052 2.03 3.06-.016.05-.318 1.09-1.05 2.163-.632.93-1.29 1.856-2.323 1.875-1.016.019-1.343-.6-2.503-.6-1.16 0-1.523.581-2.485.62-.999.038-1.76-1.005-2.398-1.932-1.303-1.897-2.3-5.36-.962-7.697.664-1.16 1.852-1.895 3.14-1.914.98-.02 1.905.66 2.503.66.598 0 1.723-.816 2.905-.696.495.02 1.884.2 2.777 1.507-.073.045-1.658.968-1.64 2.888M14.79 6.35c.528-.64.884-1.53.787-2.415-.76.03-1.68.506-2.226 1.145-.49.567-.919 1.472-.803 2.34.847.066 1.714-.43 2.242-1.07" />
    </svg>
  );
}

export function WindowsIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden {...props}>
      <path d="M3 5.5 10.6 4.4v7.05H3V5.5Zm0 13.02 7.6 1.08v-6.98H3v5.9ZM11.55 4.26 21.02 3v8.45h-9.47V4.26Zm0 8.23h9.47V21l-9.47-1.29v-7.22Z" />
    </svg>
  );
}

export function DownloadIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
      <path d="M12 3v12M7.5 10.5 12 15l4.5-4.5M5 20.5h14" />
    </svg>
  );
}

export function ArrowRight(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
      <path d="M5 12h14M13 6l6 6-6 6" />
    </svg>
  );
}

export function ArrowDown(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
      <path d="M12 5v14M6 13l6 6 6-6" />
    </svg>
  );
}

export function CheckIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
      <path d="M20 6 9 17l-5-5" />
    </svg>
  );
}

/* Feature-pillar icons ---------------------------------------------------- */
export function FeatureIcon({ id, ...props }: IconProps & { id: string }) {
  switch (id) {
    case "walkthrough":
      return (
        <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
          <rect x="3" y="5" width="18" height="12" rx="2" />
          <path d="m10 9 5 2.8-5 2.8V9Z" />
          <path d="M8 21h8M12 17v4" />
        </svg>
      );
    case "keys":
      return (
        <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
          <circle cx="8" cy="8" r="4" />
          <path d="m10.8 10.8 8.2 8.2M16 16l2.5-2.5M14 18l2.5-2.5" />
        </svg>
      );
    case "approve":
      return (
        <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
          <path d="M12 3 5 6v5c0 4.2 2.9 7.6 7 9 4.1-1.4 7-4.8 7-9V6l-7-3Z" />
          <path d="m9 11.5 2 2 4-4" />
        </svg>
      );
    case "leverage": // more output
      return (
        <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
          <circle cx="9" cy="8" r="3" />
          <path d="M3.5 19a5.5 5.5 0 0 1 11 0" />
          <path d="M16 5.5a3 3 0 0 1 0 5.8M20.5 19a5.5 5.5 0 0 0-4.2-5.3" />
        </svg>
      );
    case "visibility": // see what's being built
      return (
        <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
          <path d="M2 12s3.6-6.5 10-6.5S22 12 22 12s-3.6 6.5-10 6.5S2 12 2 12Z" />
          <circle cx="12" cy="12" r="2.6" />
        </svg>
      );
    case "landing": // approve → it lands itself (git-merge)
      return (
        <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
          <circle cx="6" cy="5.5" r="2.4" />
          <circle cx="6" cy="18.5" r="2.4" />
          <circle cx="18.5" cy="12" r="2.4" />
          <path d="M6 7.9v8.2M6 7.9c0 4.1 4.2 4.1 10 4.1" />
        </svg>
      );
    case "cost": // know what every feature cost
      return (
        <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
          <path d="M4 20.5h16M7 20.5v-6M12 20.5V10M17 20.5v-9" />
          <circle cx="17" cy="5.5" r="2.2" />
        </svg>
      );
    default:
      return null;
  }
}

/* Entry-point icons ------------------------------------------------------- */
export function EntryIcon({ id, ...props }: IconProps & { id: string }) {
  switch (id) {
    case "walkthrough":
      return (
        <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
          <rect x="3" y="6" width="14" height="10" rx="2" />
          <path d="m17 10 4-2.5v7L17 12" />
          <path d="M7 20h7" />
        </svg>
      );
    case "issue":
      return (
        <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
          <circle cx="12" cy="12" r="8" />
          <circle cx="12" cy="12" r="2.3" />
        </svg>
      );
    case "feedback":
      return (
        <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
          <path d="M5 5h14a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1H9l-4 4V6a1 1 0 0 1 1-1Z" />
          <path d="M9 10h6M9 13h3" />
        </svg>
      );
    case "ci":
      return (
        <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
          <path d="M3 12h4l2 5 4-12 2 7h6" />
        </svg>
      );
    case "direct":
      return (
        <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
          <rect x="3" y="4" width="18" height="16" rx="2" />
          <path d="m7 9 3 3-3 3M13 15h4" />
        </svg>
      );
    case "scheduled":
      return (
        <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
          <circle cx="12" cy="12" r="8" />
          <path d="M12 8v4l3 2" />
        </svg>
      );
    case "rebase":
      return (
        <svg viewBox="0 0 24 24" aria-hidden {...base} {...props}>
          <circle cx="6" cy="6" r="2.2" />
          <circle cx="6" cy="18" r="2.2" />
          <circle cx="18" cy="18" r="2.2" />
          <path d="M6 8.2v7.6M8.2 18h7.6M18 15.8V12a6 6 0 0 0-6-6" />
        </svg>
      );
    default:
      return null;
  }
}
