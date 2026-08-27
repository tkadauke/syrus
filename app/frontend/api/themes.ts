import { getJson } from "./client"

export type ThemeTokens = Record<string, string>

export type ColorTheme = {
  id: number
  slug: string
  name: string
  built_in: boolean
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

export function fetchThemes() {
  return getJson<ThemesPayload>("/api/v1/app/themes")
}

export function fetchTheme(id: number) {
  return getJson<ThemePayload>(`/api/v1/app/themes/${id}`)
}
