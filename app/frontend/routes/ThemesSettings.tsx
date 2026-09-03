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

const tokenGroups: Array<{ label: string; keys: string[] }> = [
  { label: "Surfaces, Text, Borders", keys: ["surface", "surface-raised", "border", "text-primary", "text-secondary"] },
  { label: "Brand", keys: ["brand", "brand-emphasis", "on-brand"] },
  { label: "Status", keys: ["success", "warning", "danger", "info", "neutral"] }
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
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">Manage your custom color themes.</p>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <ThemesSettingsPanel onNotice={setNotice} />
    </main>
  )
}

function ThemesSettingsPanel({ onNotice }: { onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const { colorTheme, setColorTheme } = useTheme()
  const themesQuery = useQuery({ queryKey: themesQueryKey, queryFn: fetchThemes })
  const allThemes = themesQuery.data?.themes ?? emptyThemes
  const builtInThemes = useMemo(() => allThemes.filter((theme) => theme.built_in), [allThemes])
  const customThemes = useMemo(() => allThemes.filter((theme) => !theme.built_in), [allThemes])
  const [selectedId, setSelectedId] = useState<number | null>(null)
  const [draft, setDraft] = useState<ThemeDraft | null>(null)
  const [contrastIssues, setContrastIssues] = useState<ContrastIssue[]>([])
  const [orderedThemes, setOrderedThemes] = useState<ColorTheme[]>([])
  const orderedThemesRef = useRef<ColorTheme[]>([])
  const dragIndex = useRef<number | null>(null)

  useEffect(() => {
    setOrderedThemes(customThemes)
    orderedThemesRef.current = customThemes
    setSelectedId((current) => current && customThemes.some((theme) => theme.id === current) ? current : customThemes[0]?.id ?? null)
  }, [customThemes])

  useEffect(() => {
    const selected = customThemes.find((theme) => theme.id === selectedId)
    setDraft(selected ? draftFromTheme(selected) : null)
    setContrastIssues([])
  }, [customThemes, selectedId])

  const createMutation = useMutation({
    mutationFn: () => {
      const base = colorTheme ?? builtInThemes[0] ?? allThemes[0]
      if (!base) throw new Error("No theme is available to clone.")

      return createTheme({ name: uniqueDraftName(customThemes), tokens: cloneTokens(base.tokens) })
    },
    onSuccess: (payload) => {
      queryClient.setQueryData<ThemesPayload>(themesQueryKey, (current) => mergeCustomTheme(current, payload.theme))
      setSelectedId(payload.theme.id)
      void setColorTheme(payload.theme)
      onNotice("Theme created.")
    },
    onError: () => onNotice(null)
  })

  const saveMutation = useMutation({
    mutationFn: () => {
      if (!draft) throw new Error("No theme selected.")
      return updateTheme(draft.id, { name: draft.name, tokens: draft.tokens })
    },
    onSuccess: (payload) => {
      setContrastIssues([])
      queryClient.setQueryData<ThemesPayload>(themesQueryKey, (current) => mergeCustomTheme(current, payload.theme))
      setDraft(draftFromTheme(payload.theme))
      void setColorTheme(payload.theme)
      onNotice("Theme saved.")
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
      onNotice("Theme deleted.")
    },
    onError: () => onNotice(null)
  })

  const reorderMutation = useMutation({
    mutationFn: (themes: ColorTheme[]) => reorderThemes(themes.map((theme) => theme.id)),
    onSuccess: (payload) => {
      queryClient.setQueryData<ThemesPayload>(themesQueryKey, (current) => current ? mergeCustomThemes(current, payload.themes) : current)
      onNotice("Theme order saved.")
    },
    onError: () => {
      setOrderedThemes(customThemes)
      orderedThemesRef.current = customThemes
      onNotice(null)
    }
  })

  function updateDraftName(name: string) {
    if (!draft) return
    setDraft({ ...draft, name })
  }

  function updateDraftToken(mode: "light" | "dark", key: string, value: string) {
    if (!draft) return

    const nextDraft = {
      ...draft,
      tokens: {
        ...draft.tokens,
        [mode]: {
          ...draft.tokens[mode],
          [key]: value
        }
      }
    }
    setDraft(nextDraft)
    setContrastIssues((issues) => issues.filter((issue) => !issueMatchesField(issue, mode, key)))
    if (hexPattern.test(value)) void setColorTheme(nextDraft)
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

  if (themesQuery.isPending) return <PanelMessage>Loading themes...</PanelMessage>
  if (themesQuery.isError) return <PanelMessage tone="error">{errorMessage(themesQuery.error, "Unable to load themes.")}</PanelMessage>

  return (
    <div className="grid gap-6 lg:grid-cols-[18rem_minmax(0,1fr)]">
      <section aria-label="Custom themes" className="space-y-3">
        <div className="flex items-center justify-between gap-3">
          <SectionHeading>Custom Themes</SectionHeading>
          <Button disabled={createMutation.isPending || allThemes.length === 0} onClick={() => createMutation.mutate()} size="sm">New</Button>
        </div>
        {createMutation.isError ? <PanelMessage tone="error">{errorMessage(createMutation.error, "Unable to create theme.")}</PanelMessage> : null}
        {reorderMutation.isError ? <PanelMessage tone="error">{errorMessage(reorderMutation.error, "Unable to save theme order.")}</PanelMessage> : null}
        {orderedThemes.length > 0 ? (
          <nav aria-label="Custom theme order" className="space-y-1">
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
          <PanelMessage>No custom themes yet.</PanelMessage>
        )}
      </section>

      {draft ? (
        <ThemeEditor
          contrastIssues={contrastIssues}
          deleting={deleteMutation.isPending}
          draft={draft}
          onDelete={() => {
            if (window.confirm(`Delete ${draft.name}?`)) deleteMutation.mutate(draft)
          }}
          onNameChange={updateDraftName}
          onSave={() => saveMutation.mutate()}
          onTokenChange={updateDraftToken}
          saving={saveMutation.isPending}
          saveError={saveMutation.isError ? errorMessage(saveMutation.error, "Unable to save theme.") : null}
        />
      ) : (
        <section className="rounded border border-border bg-surface p-5">
          <SectionHeading>No Theme Selected</SectionHeading>
          <p className="mt-2 text-sm text-text-secondary">Create a custom theme to edit its colors.</p>
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
  return (
    <section aria-label={`Edit ${draft.name}`} className="space-y-5 rounded border border-border bg-surface p-5">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <label className="block min-w-0 flex-1 text-sm font-medium text-text-primary" htmlFor="theme-name">
          Name
          <Input id="theme-name" maxLength={120} onChange={(event) => onNameChange(event.target.value)} required value={draft.name} />
        </label>
        <div className="flex gap-2">
          <Button disabled={saving || deleting || !draft.name.trim()} onClick={onSave}>{saving ? "Saving..." : "Save"}</Button>
          <Button disabled={saving || deleting} onClick={onDelete} variant="danger">{deleting ? "Deleting..." : "Delete"}</Button>
        </div>
      </div>

      {saveError ? <PanelMessage tone="error">{saveError}</PanelMessage> : null}

      <div className="grid gap-5 xl:grid-cols-2">
        {modes.map((mode) => (
          <div className="space-y-5" key={mode}>
            <SectionHeading>{mode === "light" ? "Light Tokens" : "Dark Tokens"}</SectionHeading>
            {tokenGroups.map((group) => (
              <fieldset className="space-y-3" key={`${mode}-${group.label}`}>
                <legend className="text-xs font-semibold uppercase text-text-secondary">{group.label}</legend>
                <div className="grid gap-3 sm:grid-cols-2">
                  {group.keys.map((key) => {
                    const value = draft.tokens[mode][key] ?? ""
                    const fieldIssues = contrastIssues.filter((issue) => issueMatchesField(issue, mode, key))
                    const inputId = `${mode}-${key}`
                    return (
                      <div className="space-y-1" key={inputId}>
                        <label className="block text-xs font-medium text-text-primary" htmlFor={inputId}>{tokenLabel(mode, key)}</label>
                        <div className="grid grid-cols-[2.5rem_minmax(0,1fr)] gap-2">
                          <Input
                            aria-label={`${tokenLabel(mode, key)} swatch`}
                            className="h-10 w-10 rounded border border-border bg-surface p-1"
                            fullWidth={false}
                            onChange={(event) => onTokenChange(mode, key, event.target.value)}
                            type="color"
                            value={hexPattern.test(value) ? value : "#000000"}
                          />
                          <Input
                            id={inputId}
                            invalid={fieldIssues.length > 0 || (value.length > 0 && !hexPattern.test(value))}
                            onChange={(event) => onTokenChange(mode, key, event.target.value)}
                            pattern="#[0-9a-fA-F]{6}"
                            value={value}
                          />
                        </div>
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
  return mergeCustomThemes(current, [theme])
}

function mergeCustomThemes(current: ThemesPayload, customThemes: ColorTheme[]): ThemesPayload {
  const customById = new Map(customThemes.map((theme) => [theme.id, theme]))
  const builtIns = current.themes.filter((theme) => theme.built_in)
  const existingCustoms = current.themes.filter((theme) => !theme.built_in && !customById.has(theme.id))
  return { themes: [...builtIns, ...customThemes, ...existingCustoms] }
}

function uniqueDraftName(customThemes: ColorTheme[]) {
  const existing = new Set(customThemes.map((theme) => theme.name))
  let index = customThemes.length + 1
  let name = `Custom Theme ${index}`
  while (existing.has(name)) {
    index += 1
    name = `Custom Theme ${index}`
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

function tokenLabel(mode: "light" | "dark", key: string) {
  return `${mode === "light" ? "Light" : "Dark"} ${key}`
}
