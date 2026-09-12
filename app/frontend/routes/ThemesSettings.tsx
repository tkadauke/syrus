import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { DragEvent } from "react"
import { useEffect, useMemo, useRef, useState } from "react"
import { createTheme, deleteTheme, fetchThemes, reorderThemes, updateTheme, type ColorTheme, type ThemesPayload, type ThemeTokens } from "../api/themes"
import { ApiError } from "../api/client"
import { Button } from "../components/Button"
import { Input } from "../components/Input"
import { PageHeading, SectionHeading } from "../components/Heading"
import { NoticeToast } from "../components/NoticeToast"
import { PanelMessage } from "../components/PanelMessage"
import { useTheme } from "../contexts/ThemeContext"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { errorMessage } from "../lib/errorMessage"

const themesQueryKey = ["themes"] as const
const modes = ["light", "dark"] as const

const tokenGroups: Array<{ labelKey: string; keys: string[] }> = [
  { labelKey: "surfaces_text_borders", keys: ["surface", "surface-raised", "border", "text-primary", "text-secondary"] },
  { labelKey: "brand", keys: ["brand", "brand-emphasis", "on-brand"] },
  { labelKey: "status", keys: ["success", "warning", "danger", "info", "neutral"] }
]

const tokenKeys = tokenGroups.flatMap((group) => group.keys)
const hexPattern = /^#[0-9a-fA-F]{6}$/
const emptyThemes: ColorTheme[] = []

type ThemeDraft = Pick<ColorTheme, "id" | "slug" | "built_in" | "position"> & {
  name: string
  tokens: ColorTheme["tokens"]
}

type ContrastIssue = {
  mode?: string
  foreground?: string
  background?: string
  message?: string
}

export function ThemesSettingsRoute() {
  const { t } = useT("settings")
  usePageTitle(t("nav.themes"))
  const [notice, setNotice] = useState<string | null>(null)

  return (
    <main aria-label={t("nav.themes")} className="mx-auto max-w-6xl space-y-6 p-6">
      <header>
        <PageHeading>{t("nav.themes")}</PageHeading>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">{t("themes.description")}</p>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <ThemesSettingsPanel onNotice={setNotice} />
    </main>
  )
}

function ThemesSettingsPanel({ onNotice }: { onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const { colorTheme, previewColorTheme, setColorTheme } = useTheme()
  const themesQuery = useQuery({ queryKey: themesQueryKey, queryFn: fetchThemes })
  const allThemes = themesQuery.data?.themes ?? emptyThemes
  const builtInThemes = useMemo(() => allThemes.filter((theme) => theme.built_in), [allThemes])
  const customThemes = useMemo(() => allThemes.filter((theme) => !theme.built_in), [allThemes])
  const [selectedId, setSelectedId] = useState<number | null>(null)
  const [draft, setDraft] = useState<ThemeDraft | null>(null)
  const [contrastIssues, setContrastIssues] = useState<ContrastIssue[]>([])
  const [orderedThemes, setOrderedThemes] = useState<ColorTheme[]>([])
  const orderedThemesRef = useRef<ColorTheme[]>([])
  const previousDraftThemeIdRef = useRef<number | null>(null)
  const dragIndex = useRef<number | null>(null)

  useEffect(() => {
    setOrderedThemes(customThemes)
    orderedThemesRef.current = customThemes

    setSelectedId((currentSelectedId) => {
      if (currentSelectedId && customThemes.some((theme) => theme.id === currentSelectedId)) return currentSelectedId
      return customThemes[0]?.id ?? null
    })
  }, [customThemes])

  useEffect(() => {
    const selected = (
      selectedId
        ? customThemes.find((theme) => theme.id === selectedId)
        : undefined
    ) ?? customThemes[0]

    const selectedDraftId = selected?.id ?? null
    setDraft((current) => {
      if (current?.id === selectedDraftId) return current
      return selected ? draftFromTheme(selected) : null
    })
    if (previousDraftThemeIdRef.current !== selectedDraftId) {
      setContrastIssues([])
      previousDraftThemeIdRef.current = selectedDraftId
    }
  }, [customThemes, selectedId])

  const createMutation = useMutation({
    mutationFn: () => {
      const base = colorTheme ?? builtInThemes[0] ?? allThemes[0]
      if (!base) throw new Error(t("themes.error_no_theme"))

      return createTheme({ name: uniqueDraftName(customThemes, t), tokens: cloneTokens(base.tokens) })
    },
    onSuccess: (payload) => {
      queryClient.setQueryData<ThemesPayload>(themesQueryKey, (current) => mergeCustomTheme(current, payload.theme))
      setSelectedId(payload.theme.id)
      void setColorTheme(payload.theme)
      onNotice(t("themes.created"))
    },
    onError: () => onNotice(null)
  })

  const saveMutation = useMutation({
    mutationFn: (themeDraft: ThemeDraft) => {
      return updateTheme(themeDraft.id, { name: themeDraft.name, tokens: themeDraft.tokens })
    },
    onSuccess: (payload) => {
      setContrastIssues([])
      queryClient.setQueryData<ThemesPayload>(themesQueryKey, (current) => mergeCustomTheme(current, payload.theme))
      setDraft(draftFromTheme(payload.theme))
      void setColorTheme(payload.theme)
      onNotice(t("themes.saved"))
    },
    onError: (error) => {
      setContrastIssues(contrastIssuesFromError(error))
      onNotice(null)
    }
  })

  const deleteMutation = useMutation({
    mutationFn: (theme: ColorTheme) => deleteTheme(theme.id),
    onSuccess: (payload) => {
      const nextCustomThemes = customThemes.filter((theme) => theme.id !== payload.deleted_theme_id)
      queryClient.setQueryData<ThemesPayload>(themesQueryKey, (current) => current ? {
        themes: current.themes.filter((theme) => theme.id !== payload.deleted_theme_id)
      } : current)
      setSelectedId(nextCustomThemes[0]?.id ?? null)
      const fallback = payload.fallback_theme_id ? allThemes.find((theme) => theme.id === payload.fallback_theme_id) : null
      if (fallback) void setColorTheme(fallback)
      onNotice(t("themes.deleted"))
    },
    onError: () => onNotice(null)
  })

  const reorderMutation = useMutation({
    mutationFn: (themes: ColorTheme[]) => reorderThemes(themes.map((theme) => theme.id)),
    onSuccess: (payload) => {
      queryClient.setQueryData<ThemesPayload>(themesQueryKey, (current) => current ? mergeCustomThemes(current, payload.themes) : current)
      onNotice(t("themes.order_saved"))
    },
    onError: () => {
      setOrderedThemes(customThemes)
      orderedThemesRef.current = customThemes
      onNotice(null)
    }
  })

  function updateDraftName(name: string) {
    setDraft((current) => current ? { ...current, name } : current)
  }

  function updateDraftToken(mode: "light" | "dark", key: string, value: string) {
    setDraft((current) => {
      if (!current) return current

      const nextDraft = {
        ...current,
        tokens: {
          ...current.tokens,
          [mode]: {
            ...current.tokens[mode],
            [key]: value
          }
        }
      }
      if (hexPattern.test(value)) previewColorTheme(nextDraft)
      return nextDraft
    })
    setContrastIssues((issues) => issues.filter((issue) => !issueMatchesField(issue, mode, key)))
  }

  function startDrag(index: number, event: DragEvent<HTMLElement>) {
    dragIndex.current = index
    event.dataTransfer.effectAllowed = "move"
  }

  function dragOver(index: number, event: DragEvent<HTMLElement>) {
    const sourceIndex = dragIndex.current
    if (sourceIndex == null) return

    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    if (sourceIndex === index) return

    const nextThemes = reorderArray(orderedThemesRef.current, sourceIndex, index)
    orderedThemesRef.current = nextThemes
    dragIndex.current = index
    setOrderedThemes(nextThemes)
  }

  function drop(event: DragEvent<HTMLElement>) {
    if (dragIndex.current == null) return

    event.preventDefault()
    const nextThemes = orderedThemesRef.current
    dragIndex.current = null
    if (sameOrder(customThemes, nextThemes)) return
    reorderMutation.mutate(nextThemes)
  }

  if (themesQuery.isPending) return <PanelMessage>{t("themes.loading")}</PanelMessage>
  if (themesQuery.isError) return <PanelMessage tone="error">{errorMessage(themesQuery.error, t("themes.error_load"))}</PanelMessage>

  return (
    <div className="space-y-6">
      <section aria-label={t("themes.custom_aria")} className="space-y-3">
        <div className="flex items-center justify-between gap-3">
          <SectionHeading>{t("themes.custom_heading")}</SectionHeading>
          <Button disabled={createMutation.isPending || allThemes.length === 0} onClick={() => createMutation.mutate()} size="sm">{t("themes.new")}</Button>
        </div>
        {createMutation.isError ? <PanelMessage tone="error">{errorMessage(createMutation.error, t("themes.error_create"))}</PanelMessage> : null}
        {reorderMutation.isError ? <PanelMessage tone="error">{errorMessage(reorderMutation.error, t("themes.error_order"))}</PanelMessage> : null}
        {orderedThemes.length > 0 ? (
          <nav aria-label={t("themes.order_aria")} className="max-h-[27.5rem] space-y-1 overflow-y-auto pr-1">
            {orderedThemes.map((theme, index) => (
              <button
                aria-current={theme.id === selectedId ? "true" : undefined}
                className={`group relative flex w-full items-center gap-3 rounded border px-3 py-2 text-left text-sm ${
                  theme.id === selectedId
                    ? "border-brand bg-brand/10 text-brand"
                    : "border-border bg-surface text-text-primary hover:bg-surface-raised"
                }`}
                draggable={!reorderMutation.isPending}
                key={theme.id}
                onClick={() => {
                  setSelectedId(theme.id)
                  void setColorTheme(theme)
                }}
                onDragEnd={() => { dragIndex.current = null }}
                onDragOver={(event) => dragOver(index, event)}
                onDragStart={(event) => startDrag(index, event)}
                onDrop={drop}
                type="button"
              >
                <DragHandle />
                <span aria-hidden="true" className="h-5 w-5 shrink-0 rounded border border-black/10 dark:border-white/20" style={{ backgroundColor: theme.tokens.light.brand }} />
                <span className="min-w-0 flex-1 truncate">{theme.name}</span>
              </button>
            ))}
          </nav>
        ) : (
          <PanelMessage>{t("themes.empty")}</PanelMessage>
        )}
      </section>

      {draft ? (
        <ThemeEditor
          contrastIssues={contrastIssues}
          deleting={deleteMutation.isPending}
          draft={draft}
          onDelete={() => {
            if (window.confirm(t("themes.confirm_delete", { name: draft.name }))) deleteMutation.mutate(draft)
          }}
          onNameChange={updateDraftName}
          onSave={() => {
            if (!draftTokensValid(draft)) return
            saveMutation.mutate(draft)
          }}
          onTokenChange={updateDraftToken}
          saving={saveMutation.isPending}
          saveError={saveMutation.isError ? errorMessage(saveMutation.error, t("themes.error_save")) : null}
        />
      ) : (
        <section className="rounded border border-border bg-surface p-5">
          <SectionHeading>{t("themes.no_selection_heading")}</SectionHeading>
          <p className="mt-2 text-sm text-text-secondary">{t("themes.no_selection_description")}</p>
        </section>
      )}
    </div>
  )
}

function ThemeEditor({
  contrastIssues,
  deleting,
  draft,
  onDelete,
  onNameChange,
  onSave,
  onTokenChange,
  saveError,
  saving
}: {
  contrastIssues: ContrastIssue[]
  deleting: boolean
  draft: ThemeDraft
  onDelete: () => void
  onNameChange: (name: string) => void
  onSave: () => void
  onTokenChange: (mode: "light" | "dark", key: string, value: string) => void
  saveError: string | null
  saving: boolean
  }) {
  const { t } = useT("settings")
  const hasInvalidTokens = !draftTokensValid(draft)

  return (
    <section aria-label={t("themes.edit_aria", { name: draft.name })} className="space-y-5 rounded border border-border bg-surface p-5">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <label className="block min-w-0 flex-1 text-sm font-medium text-text-primary" htmlFor="theme-name">
          {t("themes.name")}
          <Input id="theme-name" maxLength={120} onChange={(event) => onNameChange(event.target.value)} required value={draft.name} />
        </label>
        <div className="flex gap-2">
          <Button disabled={saving || deleting || !draft.name.trim() || hasInvalidTokens} onClick={onSave}>{saving ? t("themes.saving") : t("themes.save")}</Button>
          <Button disabled={saving || deleting} onClick={onDelete} variant="danger">{deleting ? t("themes.deleting") : t("themes.delete")}</Button>
        </div>
      </div>

      {saveError ? <PanelMessage tone="error">{saveError}</PanelMessage> : null}

      <div className="grid gap-5 xl:grid-cols-2">
        {modes.map((mode) => (
          <div className="space-y-5" key={mode}>
            <SectionHeading>{mode === "light" ? t("themes.light_tokens") : t("themes.dark_tokens")}</SectionHeading>
            {tokenGroups.map((group) => (
              <fieldset className="space-y-3" key={`${mode}-${group.labelKey}`}>
                <legend className="text-xs font-semibold uppercase text-text-secondary">{t(`themes.token_groups.${group.labelKey}`)}</legend>
                <div className="grid gap-3">
                  {group.keys.map((key) => {
                    const value = draft.tokens[mode][key] ?? ""
                    const invalidHex = value.length > 0 && !hexPattern.test(value)
                    const fieldIssues = contrastIssues.filter((issue) => issueMatchesField(issue, mode, key))
                    const inputId = `${mode}-${key}`
                    return (
                      <div className="space-y-1" key={inputId}>
                        <label className="block text-xs font-medium text-text-primary" htmlFor={inputId}>{tokenLabel(mode, key, t)}</label>
                        <div className="grid grid-cols-[2.5rem_minmax(0,1fr)] gap-2">
                          <Input
                            aria-label={t("themes.swatch_aria", { label: tokenLabel(mode, key, t) })}
                            className="h-10 w-10 rounded border border-border bg-surface p-1"
                            fullWidth={false}
                            onChange={(event) => onTokenChange(mode, key, event.target.value)}
                            type="color"
                            value={hexPattern.test(value) ? value : "#000000"}
                          />
                          <Input
                            id={inputId}
                            className="min-w-[7.5rem] font-mono"
                            invalid={fieldIssues.length > 0 || invalidHex}
                            onChange={(event) => onTokenChange(mode, key, event.target.value)}
                            pattern="#[0-9a-fA-F]{6}"
                            value={value}
                          />
                        </div>
                        {invalidHex ? <p className="text-xs text-danger" role="alert">{t("themes.invalid_hex")}</p> : null}
                        {fieldIssues.map((issue) => (
                          <p className="text-xs text-danger" key={`${issue.mode}-${issue.foreground}-${issue.background}-${issue.message}`} role="alert">{issue.message}</p>
                        ))}
                      </div>
                    )
                  })}
                </div>
              </fieldset>
            ))}
          </div>
        ))}
      </div>
    </section>
  )
}

function DragHandle() {
  return (
    <span aria-hidden="true" className="grid h-5 w-3 shrink-0 grid-cols-2 gap-0.5 text-text-secondary">
      {Array.from({ length: 6 }).map((_, index) => <span className="h-1 w-1 rounded-full bg-current" key={index} />)}
    </span>
  )
}

function draftFromTheme(theme: ColorTheme): ThemeDraft {
  return {
    id: theme.id,
    slug: theme.slug,
    name: theme.name,
    built_in: theme.built_in,
    position: theme.position,
    tokens: cloneTokens(theme.tokens)
  }
}

function cloneTokens(tokens: ColorTheme["tokens"]): ColorTheme["tokens"] {
  return {
    light: cloneModeTokens(tokens.light),
    dark: cloneModeTokens(tokens.dark)
  }
}

function cloneModeTokens(tokens: ThemeTokens): ThemeTokens {
  return Object.fromEntries(tokenKeys.map((key) => [key, tokens[key] ?? "#000000"]))
}

function mergeCustomTheme(current: ThemesPayload | undefined, theme: ColorTheme): ThemesPayload | undefined {
  if (!current) return current
  const existingIndex = current.themes.findIndex((candidate) => candidate.id === theme.id)
  if (existingIndex >= 0) {
    const themes = [...current.themes]
    themes[existingIndex] = theme
    return { themes }
  }

  const insertAfterIndex = insertionIndexForCustomTheme(current.themes, theme)
  return {
    themes: [
      ...current.themes.slice(0, insertAfterIndex),
      theme,
      ...current.themes.slice(insertAfterIndex)
    ]
  }
}

function mergeCustomThemes(current: ThemesPayload, customThemes: ColorTheme[]): ThemesPayload {
  const customById = new Map(customThemes.map((theme) => [theme.id, theme]))
  const builtIns = current.themes.filter((theme) => theme.built_in)
  const existingCustoms = current.themes.filter((theme) => !theme.built_in && !customById.has(theme.id))
  return { themes: [...builtIns, ...customThemes, ...existingCustoms] }
}

function uniqueDraftName(customThemes: ColorTheme[], t: (key: string, options?: Record<string, unknown>) => string) {
  const existing = new Set(customThemes.map((theme) => theme.name))
  let index = customThemes.length + 1
  let name = t("themes.default_name", { index })
  while (existing.has(name)) {
    index += 1
    name = t("themes.default_name", { index })
  }
  return name
}

function contrastIssuesFromError(error: unknown): ContrastIssue[] {
  if (!(error instanceof ApiError) || error.code !== "contrast_check_failed" || !Array.isArray(error.issues)) return []

  return error.issues.filter((issue): issue is ContrastIssue => issue != null && typeof issue === "object")
}

function issueMatchesField(issue: ContrastIssue, mode: "light" | "dark", key: string) {
  return issue.mode === mode && (issue.foreground === key || issue.background === key)
}

function reorderArray<T>(items: T[], from: number, to: number) {
  const next = [...items]
  const [moved] = next.splice(from, 1)
  next.splice(to, 0, moved)
  return next
}

function sameOrder(a: ColorTheme[], b: ColorTheme[]) {
  return a.length === b.length && a.every((theme, index) => theme.id === b[index]?.id)
}

function draftTokensValid(draft: ThemeDraft) {
  return modes.every((mode) => tokenKeys.every((key) => hexPattern.test(draft.tokens[mode][key] ?? "")))
}

function insertionIndexForCustomTheme(themes: ColorTheme[], theme: ColorTheme) {
  const targetPosition = theme.position ?? Number.POSITIVE_INFINITY
  const firstCustomIndex = themes.findIndex((candidate) => !candidate.built_in)
  let insertIndex = firstCustomIndex >= 0 ? firstCustomIndex : themes.length

  themes.forEach((candidate, index) => {
    if (candidate.built_in) return

    const candidatePosition = candidate.position ?? Number.POSITIVE_INFINITY
    if (candidatePosition <= targetPosition) insertIndex = index + 1
  })

  return insertIndex
}

function tokenLabel(mode: "light" | "dark", key: string, t: (key: string, options?: Record<string, unknown>) => string) {
  return t("themes.token_label", { mode: mode === "light" ? t("themes.light") : t("themes.dark"), token: key })
}
