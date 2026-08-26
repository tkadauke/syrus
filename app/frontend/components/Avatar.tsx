export type AvatarSize = "xs" | "sm" | "normal" | "large"

const DIMENSIONS: Record<AvatarSize, string> = {
  xs: "h-5 w-5 text-2xs",
  sm: "h-6 w-6 text-2xs",
  normal: "h-12 w-12 text-base",
  large: "h-20 w-20 text-2xl"
}

// Shared avatar/name display: an image when avatarUrl is set, otherwise a
// ring-bordered initials fallback. Originally local to Profiles.tsx (team
// directory); extracted so other surfaces (e.g. group chat participant UI)
// reuse the same pattern instead of re-implementing it.
export function Avatar({ avatarUrl, name, size = "normal" }: { avatarUrl: string | null | undefined; name: string; size?: AvatarSize }) {
  const dimension = DIMENSIONS[size]
  const initials = name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]?.toUpperCase()).join("") || "U"

  if (avatarUrl) {
    return <img alt="" className={`${dimension} shrink-0 rounded-full object-cover ring-1 ring-gray-200 dark:ring-gray-700`} src={avatarUrl} />
  }

  return (
    <div aria-hidden="true" className={`${dimension} flex shrink-0 items-center justify-center rounded-full bg-gray-100 font-semibold text-gray-500 ring-1 ring-gray-200 dark:bg-gray-800 dark:text-gray-400 dark:ring-gray-700`}>
      {initials}
    </div>
  )
}
