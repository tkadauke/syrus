import type { ColorTheme, ThemeTokens } from "../api/themes"

// Mirrors Theme::EXTENDED_TOKEN_GROUPS (app/models/theme.rb): the non-color
// token groups (shape, shadow, spacing, density, typography) every theme
// payload carries alongside "light"/"dark", already merged with defaults
// server-side by Theme#tokens_with_defaults. Unlike color tokens these don't
// vary between light and dark, so there's no per-mode selection here -- just
// one flat set of custom-property values.
export const EXTENDED_TOKEN_GROUPS = ["shape", "shadow", "spacing", "density", "typography"] as const

export function extendedTokenProperties(tokens: ColorTheme["tokens"]): ThemeTokens {
  return EXTENDED_TOKEN_GROUPS.reduce<ThemeTokens>((acc, group) => ({ ...acc, ...tokens[group] }), {})
}
