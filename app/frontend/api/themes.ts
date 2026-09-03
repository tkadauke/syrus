import { deleteJson, getJson, patchJson, postJson } from "./client"

export type ThemeTokens = Record<string, string>

export const THEME_TOKEN_KEYS = [
  "brand",
  "brand-emphasis",
  "surface",
  "surface-raised",
  "border",
  "text-primary",
  "text-secondary",
  "success",
  "warning",
  "danger",
  "info",
  "neutral",
  "on-brand"
] as const

export type ThemeTokenKey = typeof THEME_TOKEN_KEYS[number]
export type ThemeMode = "light" | "dark"

export type ColorTheme = {
  id: number
  slug: string
  name: string
  built_in: boolean
  position: number | null
  tokens: {
    light: ThemeTokens
    dark: ThemeTokens
  }
}

export type ThemesPayload = {
  themes: ColorTheme[]
}

export type ThemePayload = {
  theme: ColorTheme
}

export type ThemeDeletePayload = {
  deleted_theme_id: number
  fallback_theme_id: number | null
}

export type ThemeInput = {
  name?: string
  tokens?: ColorTheme["tokens"]
}

export function fetchThemes() {
  return getJson<ThemesPayload>("/api/v1/app/themes")
}

export function fetchTheme(id: number) {
  return getJson<ThemePayload>(`/api/v1/app/themes/${id}`)
}

export function createTheme(theme: Required<ThemeInput>) {
  return postJson<ThemePayload>("/api/v1/app/themes", { theme })
}

export function updateTheme(id: number, theme: ThemeInput) {
  return patchJson<ThemePayload>(`/api/v1/app/themes/${id}`, { theme })
}

export function deleteTheme(id: number) {
  return deleteJson<ThemeDeletePayload>(`/api/v1/app/themes/${id}`)
}

export function reorderThemes(ids: number[]) {
  return patchJson<ThemesPayload>("/api/v1/app/themes/reorder", { ids })
}
