import { deleteJson, getJson, patchJson, postJson } from "./client"

export type ThemeTokens = Record<string, string>

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

export type ThemeInput = {
  name?: string
  tokens?: ColorTheme["tokens"]
}

export type DeleteThemePayload = {
  deleted_theme_id: number
  fallback_theme_id: number | null
}

export function fetchThemes() {
  return getJson<ThemesPayload>("/api/v1/app/themes")
}

export function fetchTheme(id: number) {
  return getJson<ThemePayload>(`/api/v1/app/themes/${id}`)
}

export function createTheme(input: ThemeInput) {
  return postJson<ThemePayload>("/api/v1/app/themes", { theme: input })
}

export function updateTheme(id: number, input: ThemeInput) {
  return patchJson<ThemePayload>(`/api/v1/app/themes/${id}`, { theme: input })
}

export function deleteTheme(id: number) {
  return deleteJson<DeleteThemePayload>(`/api/v1/app/themes/${id}`)
}

export function reorderThemes(ids: number[]) {
  return patchJson<ThemesPayload>("/api/v1/app/themes/reorder", { ids })
}
