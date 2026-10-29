import colorConfig from "../../../config/appearance/colors.json"
import avatarConfig from "../../../config/appearance/avatars.json"

export type AccentFamilyId = (typeof colorConfig.families)[number]["id"]
export type AccentColor = (typeof colorConfig.families)[number]["colors"][number]
export type AccentShade = -2 | -1 | 0 | 1 | 2
export type AccentRef = { family: AccentFamilyId; index: number; shade: AccentShade }
export type AccentSelection = { accentHex: string; accentRef: AccentRef }
export type BundledAvatar = (typeof avatarConfig)[number]

export const HUE_COLUMNS = colorConfig.hue_columns
export const ACCENT_FAMILIES = colorConfig.families
export const ACCENT_COLORS: readonly AccentColor[] = ACCENT_FAMILIES.flatMap((family) => family.colors)
export const PICKER_TONES = colorConfig.picker_tones as readonly AccentFamilyId[]
export const DEFAULT_AGENT_ORDER = colorConfig.default_agent_order
export const THEME_COLORS = colorConfig.theme_colors
export const BUNDLED_AVATARS: readonly BundledAvatar[] = avatarConfig

const avatarsByKey = new Map(BUNDLED_AVATARS.map((avatar) => [avatar.key, avatar]))

export function resolveBundledAvatar(avatarKey: string | null | undefined): BundledAvatar | null {
  return avatarsByKey.get(avatarKey || "") || null
}

const rgb = (hex: string) => {
  const n = Number.parseInt(hex.slice(1), 16)
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
}

export function mixHex(hex: string, p: number, target: string): string {
  const a = rgb(hex)
  const b = rgb(target)
  const k = p / 100
  return `#${a
    .map((value, index) =>
      Math.round(value * k + b[index] * (1 - k))
        .toString(16)
        .padStart(2, "0")
    )
    .join("")}`.toUpperCase()
}

export function accentVariant(baseHex: string, shade: AccentShade): string {
  if (shade === -2) return mixHex(baseHex, 72, "#000000")
  if (shade === -1) return mixHex(baseHex, 86, "#000000")
  if (shade === 1) return mixHex(baseHex, 82, "#FFFFFF")
  if (shade === 2) return mixHex(baseHex, 64, "#FFFFFF")
  return baseHex.toUpperCase()
}

const toLinear = (value: number) => {
  value /= 255
  return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
}

export function luminance(hex: string): number {
  const [r, g, b] = rgb(hex).map(toLinear)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

export function onColor(hex: string): "#FFFFFF" | "#141414" {
  const value = luminance(hex)
  const whiteContrast = 1.05 / (value + 0.05)
  const darkContrast = (value + 0.05) / (luminance("#141414") + 0.05)
  if (whiteContrast >= 4.5) return "#FFFFFF"
  if (darkContrast >= 4.5) return "#141414"
  return whiteContrast >= darkContrast ? "#FFFFFF" : "#141414"
}

export const RAMP_STEPS = [
  ["wash", 8, "#FFFFFF"],
  ["tint", 16, "#FFFFFF"],
  ["soft", 30, "#FFFFFF"],
  ["muted", 55, "#FFFFFF"],
  ["light", 78, "#FFFFFF"],
  ["solid", 100, null],
  ["hover", 86, "#000000"],
  ["pressed", 70, "#000000"],
  ["ink", 45, "#000000"]
] as const

export function accentRamp(hex: string): Record<(typeof RAMP_STEPS)[number][0], string> {
  return Object.fromEntries(RAMP_STEPS.map(([key, percentage, target]) => [key, target ? mixHex(hex, percentage, target) : hex.toUpperCase()])) as Record<
    (typeof RAMP_STEPS)[number][0],
    string
  >
}

export function accentDark(hex: string, surface = "#161618") {
  return {
    tint: mixHex(hex, 24, surface),
    wash: mixHex(hex, 12, surface),
    border: mixHex(hex, 35, surface),
    ring: mixHex(hex, 40, surface),
    ink: mixHex(hex, 55, "#FFFFFF")
  }
}

function oklab(hexOrLinear: string | number[]) {
  const [r, g, b] = typeof hexOrLinear === "string" ? rgb(hexOrLinear).map(toLinear) : hexOrLinear
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
  ]
}

export function colorDistance(a: string, b: string): number {
  const p = oklab(a)
  const q = oklab(b)
  return Math.hypot(p[0] - q[0], p[1] - q[1], p[2] - q[2]) * 100
}

function familyFor(id: AccentFamilyId) {
  return ACCENT_FAMILIES.find((family) => family.id === id)
}

export function resolveAccentRef(ref: AccentRef): AccentSelection | null {
  const family = familyFor(ref.family)
  const color = family?.colors[ref.index]
  if (!color || ![-2, -1, 0, 1, 2].includes(ref.shade)) return null
  return { accentHex: accentVariant(color.hex, ref.shade), accentRef: ref }
}

export function resolveAccentSelection(accentHex: string, accentRef?: AccentRef | null): AccentSelection {
  const normalizedHex = accentHex.toUpperCase()
  const referenced = accentRef ? resolveAccentRef(accentRef) : null
  if (referenced?.accentHex === normalizedHex) return referenced

  let nearest = { family: ACCENT_FAMILIES[0], index: 0, distance: Number.POSITIVE_INFINITY }
  for (const family of ACCENT_FAMILIES) {
    family.colors.forEach((color, index) => {
      const distance = colorDistance(normalizedHex, color.hex)
      if (distance < nearest.distance) nearest = { family, index, distance }
    })
  }
  const color = nearest.family.colors[nearest.index]
  return { accentHex: color.hex.toUpperCase(), accentRef: { family: nearest.family.id, index: nearest.index, shade: 0 } }
}

export function defaultAccentSelection(otherAccentHexes: readonly string[] = []): AccentSelection {
  const used = new Set(otherAccentHexes.map((hex) => hex.toUpperCase()))
  const hex = DEFAULT_AGENT_ORDER.find((candidate) => !used.has(candidate.toUpperCase())) ?? DEFAULT_AGENT_ORDER[0]
  return resolveAccentSelection(hex)
}

const CVD = {
  protan: [
    [0.152286, 1.052583, -0.204868],
    [0.114503, 0.786281, 0.099216],
    [-0.003882, -0.048116, 1.051998]
  ],
  deutan: [
    [0.367322, 0.860646, -0.227968],
    [0.280085, 0.672501, 0.047413],
    [-0.01182, 0.04294, 0.968881]
  ],
  tritan: [
    [1.255528, -0.076749, -0.178779],
    [-0.078411, 0.930809, 0.147602],
    [0.004733, 0.691367, 0.3039]
  ]
}

function simulate(hex: string, kind: keyof typeof CVD) {
  const linear = rgb(hex).map(toLinear)
  return CVD[kind].map((row) => Math.min(1, Math.max(0, row[0] * linear[0] + row[1] * linear[1] + row[2] * linear[2])))
}

export function worstCaseDistance(a: string, b: string): number {
  const views = [colorDistance(a, b)]
  for (const kind of Object.keys(CVD) as (keyof typeof CVD)[]) {
    const p = oklab(simulate(a, kind))
    const q = oklab(simulate(b, kind))
    views.push(Math.hypot(p[0] - q[0], p[1] - q[1], p[2] - q[2]) * 100)
  }
  return Math.min(...views)
}

export function isCloseToTheme(accentHex: string, themeHex: string): boolean {
  return colorDistance(accentHex, themeHex) < 13
}

export function accentProperties(hex: string): Record<`--agent-${string}`, string> {
  const ramp = accentRamp(hex)
  return {
    "--agent-solid": ramp.solid,
    "--agent-wash": ramp.wash,
    "--agent-tint": ramp.tint,
    "--agent-soft": ramp.soft,
    "--agent-muted": ramp.muted,
    "--agent-light": ramp.light,
    "--agent-hover": ramp.hover,
    "--agent-pressed": ramp.pressed,
    "--agent-ink": ramp.ink,
    "--agent-on": onColor(hex)
  }
}
