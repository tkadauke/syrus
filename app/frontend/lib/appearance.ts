import colorConfig from "../../../config/appearance/colors.json"
import avatarConfig from "../../../config/appearance/avatars.json"

export type AppearanceMode = "light" | "dark"
export type AppearanceColor = (typeof colorConfig.colors)[number]
export type BundledAvatar = (typeof avatarConfig)[number]

export const APPEARANCE_COLORS: readonly AppearanceColor[] = colorConfig.colors
export const BUNDLED_AVATARS: readonly BundledAvatar[] = avatarConfig

const colorsByKey = new Map(APPEARANCE_COLORS.map((color) => [color.key, color]))
const avatarsByKey = new Map(BUNDLED_AVATARS.map((avatar) => [avatar.key, avatar]))

export function resolveAppearanceColor(colorKey: string | null | undefined, mode: AppearanceMode): AppearanceColor & { value: string } {
  const color = colorsByKey.get(colorKey || "") || APPEARANCE_COLORS[0]
  return { ...color, value: color[mode] }
}

export function resolveBundledAvatar(avatarKey: string | null | undefined): BundledAvatar | null {
  return avatarsByKey.get(avatarKey || "") || null
}

// Handles are ASCII by contract, so this FNV-1a implementation matches the
// backend helper byte-for-byte without requiring an async digest API.
export function defaultColorKey(handle: string): string {
  let hash = 0x811c9dc5
  for (const character of handle.toLowerCase()) {
    hash = Math.imul(hash ^ character.charCodeAt(0), 0x01000193) >>> 0
  }
  return APPEARANCE_COLORS[hash % APPEARANCE_COLORS.length].key
}
