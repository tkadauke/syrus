import { getJson, patchJson } from "./client"

export type ReviewDiffSettings = {
  line_wrapping: "wrap" | "scroll"
  desktop_view: "unified" | "split"
  syntax_highlighting: boolean
  intraline_highlighting: "word" | "off"
  whitespace: "show" | "trim_trailing"
  tab_width: number
  density: "compact" | "comfortable" | "spacious"
  line_numbers: boolean
  file_list: boolean
}

export type ReviewDiffSettingsPayload = {
  review_diff_settings: ReviewDiffSettings
  message?: string
}

export const DEFAULT_REVIEW_DIFF_SETTINGS: ReviewDiffSettings = {
  line_wrapping: "scroll",
  desktop_view: "unified",
  syntax_highlighting: true,
  intraline_highlighting: "word",
  whitespace: "show",
  tab_width: 2,
  density: "comfortable",
  line_numbers: true,
  file_list: true
}

export function fetchReviewDiffSettings() {
  return getJson<ReviewDiffSettingsPayload>("/api/v1/app/review_diff_settings")
}

export function patchReviewDiffSettings(settings: Partial<ReviewDiffSettings>) {
  return patchJson<ReviewDiffSettingsPayload>("/api/v1/app/review_diff_settings", { review_diff_settings: settings })
}
