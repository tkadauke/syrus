// Shared initials-fallback avatar for group chat participant UI (the header
// chip strip and the invite picker's user list), mirroring the avatar/name
// display pattern already used in Profiles.tsx.
export function ParticipantAvatar({ avatarUrl, name, size = "sm" }: { avatarUrl: string | null | undefined; name: string; size?: "sm" | "md" }) {
  const dimension = size === "md" ? "h-6 w-6 text-[10px]" : "h-5 w-5 text-[9px]"
  const initials = name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]?.toUpperCase()).join("") || "U"

  if (avatarUrl) {
    return <img alt="" className={`${dimension} shrink-0 rounded-full object-cover ring-1 ring-gray-200 dark:ring-gray-700`} src={avatarUrl} />
  }

  return (
    <span aria-hidden="true" className={`flex ${dimension} shrink-0 items-center justify-center rounded-full bg-gray-200 font-semibold text-gray-500 dark:bg-gray-700 dark:text-gray-300`}>
      {initials}
    </span>
  )
}
