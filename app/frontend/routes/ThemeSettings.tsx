import { useEffect, useMemo, useRef, useState, type DragEvent, type FormEvent } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Button } from "../components/Button"
import { Input } from "../components/Input"
import { NoticeToast } from "../components/NoticeToast"
import { PageHeading, SectionHeading } from "../components/Heading"
import { PanelMessage } from "../components/PanelMessage"
import { createTheme, deleteTheme, fetchThemes, reorderThemes, updateTheme, type ColorTheme, type ThemeMode, type ThemesPayload, type ThemeTokenKey } from "../api/themes"
import { ApiError } from "../api/client"
import { useTheme } from "../contexts/ThemeContext"
import { useConfirm } from "../hooks/useConfirm"
import { usePageTitle } from "../hooks/usePageTitle"
import { errorMessage } from "../lib/errorMessage"

const themeQueryKey = ["themes"] as const
const themeModes: ThemeMode[] = ["light", "dark"]
const emptyThemes: ColorTheme[] = []
const tokenGroups: Array<{ label: string; keys: ThemeTokenKey[] }> = [
  { label: "Surfaces, text, and borders", keys: ["surface", "surface-raised", "border", "text-primary", "text-secondary"] },
  { label: "Brand", keys: ["brand", "brand-emphasis", "on-brand"] },
  { label: "Status colors", keys: ["success", "warning", "danger", "info", "neutral"] }
]

type ContrastIssue = {
  mode?: string
  foreground?: string
  message?: string
}

export function ThemeSettingsRoute() {
  usePageTitle("Themes")
  const [notice, setNotice] = useState<string | null>(null)

  return (
    <main aria-label="Themes" className="mx-auto max-w-6xl space-y-6 p-6">
      <header>
        <PageHeading>Themes</PageHeading>
        <p className="mt-1 text-sm text-text-secondary">Manage your custom color themes.</p>
      </header>
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <ThemeSettingsPanel onNotice={setNotice} />
    </main>
  )
}

function ThemeSettingsPanel({ onNotice }: { onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const { colorTheme, setColorTheme, previewColorTheme } = useTheme()
  const { confirm, dialog } = useConfirm()
  const themesQuery = useQuery({ queryKey: themeQueryKey, queryFn: fetchThemes })
  const themes = themesQuery.data?.themes ?? emptyThemes
  const customThemes = useMemo(() => themes.filter((theme) => !theme.built_in), [themes])
  const [selectedId, setSelectedId] = useState<number | null>(null)
  const [orderedThemes, setOrderedThemes] = useState<ColorTheme[]>([])
  const orderedThemesRef = useRef<ColorTheme[]>([])
  const dragIndex = useRef<number | null>(null)
  const selectedTheme = customThemes.find((theme) => theme.id === selectedId) ?? customThemes[0] ?? null

  useEffect(() => {
    setOrderedThemes(customThemes)
    orderedThemesRef.current = customThemes
    if (selectedId == null || !customThemes.some((theme) => theme.id === selectedId)) {
      setSelectedId(customThemes[0]?.id ?? null)
    }
  }, [customThemes, selectedId])

  const createMutation = useMutation({
    mutationFn: () => {
      const baseTheme = colorTheme ?? themes[0]
      if (!baseTheme) throw new Error("No theme is available to copy.")
      return createTheme({ name: nextThemeName(customThemes), tokens: baseTheme.tokens })
    },
    onSuccess: (payload) => {
      queryClient.setQueryData<ThemesPayload>(themeQueryKey, (current) => addThemeToCache(current, payload.theme))
      setSelectedId(payload.theme.id)
      onNotice("Theme created.")
    }
  })

  const reorderMutation = useMutation({
    mutationFn: (ids: number[]) => reorderThemes(ids),
    onSuccess: (payload) => {
      queryClient.setQueryData<ThemesPayload>(themeQueryKey, (current) => replaceCustomThemes(current, payload.themes))
      onNotice("Theme order saved.")
    }
  })

  const deleteMutation = useMutation({
    mutationFn: (theme: ColorTheme) => deleteTheme(theme.id),
    onSuccess: (_payload, deletedTheme) => {
      const fallback = themes.find((theme) => theme.slug === "terracotta") ?? themes.find((theme) => theme.built_in)
      queryClient.setQueryData<ThemesPayload>(themeQueryKey, (current) => removeThemeFromCache(current, deletedTheme.id))
      if (colorTheme?.id === deletedTheme.id && fallback) void setColorTheme(fallback)
      setSelectedId((current) => current === deletedTheme.id ? null : current)
      onNotice("Theme deleted.")
    }
  })

  function startThemeDrag(index: number, event: DragEvent<HTMLElement>) {
    dragIndex.current = index
    event.dataTransfer.effectAllowed = "move"
  }

  function dragOverTheme(index: number, event: DragEvent<HTMLElement>) {
    const sourceIndex = dragIndex.current
    if (sourceIndex == null) return

    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    if (sourceIndex === index) return

    const nextThemes = reorderList(orderedThemesRef.current, sourceIndex, index)
    orderedThemesRef.current = nextThemes
    dragIndex.current = index
    setOrderedThemes(nextThemes)
  }

  function dropTheme(event: DragEvent<HTMLElement>) {
    if (dragIndex.current == null) return

    event.preventDefault()
    const nextThemes = orderedThemesRef.current
    dragIndex.current = null
    const nextIds = nextThemes.map((theme) => theme.id)
    if (nextIds.join(",") === customThemes.map((theme) => theme.id).join(",")) return

    reorderMutation.mutate(nextIds)
  }

  async function confirmDelete(theme: ColorTheme) {
    if (!await confirm({ message: `Delete ${theme.name}?`, confirmLabel: "Delete", destructive: true })) return
    onNotice(null)
    deleteMutation.mutate(theme)
  }

  if (themesQuery.isPending) return <PanelMessage>Loading themes...</PanelMessage>
  if (themesQuery.isError) return <PanelMessage tone="error">{errorMessage(themesQuery.error, "Unable to load themes.")}</PanelMessage>

  return (
    <div className="grid gap-6 lg:grid-cols-[18rem_minmax(0,1fr)]">
      {dialog}
      <section className="rounded border border-border bg-surface p-4">
        <div className="flex items-center justify-between gap-3">
          <SectionHeading>Your Themes</SectionHeading>
          <Button disabled={createMutation.isPending || themes.length === 0} onClick={() => createMutation.mutate()} size="sm">
            New
          </Button>
        </div>
        {createMutation.isError ? <p className="mt-3 text-sm text-danger" role="alert">{errorMessage(createMutation.error, "Unable to create theme.")}</p> : null}
        {reorderMutation.isError ? <p className="mt-3 text-sm text-danger" role="alert">{errorMessage(reorderMutation.error, "Unable to save theme order.")}</p> : null}
        {deleteMutation.isError ? <p className="mt-3 text-sm text-danger" role="alert">{errorMessage(deleteMutation.error, "Unable to delete theme.")}</p> : null}
        {orderedThemes.length === 0 ? (
          <p className="mt-4 text-sm text-text-secondary">No custom themes yet.</p>
        ) : (
          <ol aria-label="Custom themes" className="mt-4 space-y-2">
            {orderedThemes.map((theme, index) => (
              <li
                className={`rounded border ${selectedTheme?.id === theme.id ? "border-brand bg-brand/10" : "border-border bg-surface-raised"}`}
                draggable={!reorderMutation.isPending}
                key={theme.id}
                onDragEnd={() => { dragIndex.current = null }}
                onDragOver={(event) => dragOverTheme(index, event)}
                onDragStart={(event) => startThemeDrag(index, event)}
                onDrop={dropTheme}
              >
                <button
                  className="flex w-full items-center gap-3 px-3 py-2 text-left"
                  onClick={() => setSelectedId(theme.id)}
                  type="button"
                >
                  <span aria-hidden="true" className="cursor-grab text-text-secondary">::</span>
                  <span aria-hidden="true" className="h-4 w-4 shrink-0 rounded-full border border-border" style={{ backgroundColor: theme.tokens.light.brand }} />
                  <span className="min-w-0 flex-1 truncate text-sm font-medium text-text-primary">{theme.name}</span>
                </button>
              </li>
            ))}
          </ol>
        )}
      </section>
      {selectedTheme ? (
        <ThemeEditor
          active={colorTheme?.id === selectedTheme.id}
          key={selectedTheme.id}
          onDelete={() => void confirmDelete(selectedTheme)}
          onNotice={onNotice}
          onPreview={previewColorTheme}
          onSelect={() => void setColorTheme(selectedTheme)}
          theme={selectedTheme}
        />
      ) : (
        <PanelMessage>Create a custom theme to edit token colors.</PanelMessage>
      )}
    </div>
  )
}

function ThemeEditor({ active, onDelete, onNotice, onPreview, onSelect, theme }: {
  active: boolean
  onDelete: () => void
  onNotice: (message: string | null) => void
  onPreview: (theme: ColorTheme | null) => void
  onSelect: () => void
  theme: ColorTheme
}) {
  const queryClient = useQueryClient()
  const [name, setName] = useState(theme.name)
  const [tokens, setTokens] = useState(theme.tokens)
  const [issues, setIssues] = useState<ContrastIssue[]>([])
  const draftTheme = useMemo(() => ({ ...theme, name, tokens }), [name, theme, tokens])

  useEffect(() => {
    onPreview(draftTheme)
  }, [draftTheme, onPreview])

  const saveMutation = useMutation({
    mutationFn: () => updateTheme(theme.id, { name, tokens }),
    onMutate: () => {
      setIssues([])
      onNotice(null)
    },
    onSuccess: (payload) => {
      queryClient.setQueryData<ThemesPayload>(themeQueryKey, (current) => updateThemeInCache(current, payload.theme))
      setName(payload.theme.name)
      setTokens(payload.theme.tokens)
      onPreview(payload.theme)
      onNotice("Theme saved.")
    },
    onError: (error) => setIssues(contrastIssuesFrom(error))
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    saveMutation.mutate()
  }

  function changeToken(mode: ThemeMode, key: ThemeTokenKey, value: string) {
    setTokens((current) => ({
      ...current,
      [mode]: {
        ...current[mode],
        [key]: value
      }
    }))
  }

  return (
    <section className="rounded border border-border bg-surface p-5">
      <form className="space-y-6" onSubmit={submit}>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div className="min-w-0 flex-1">
            <SectionHeading>Edit Theme</SectionHeading>
            <label className="mt-3 block text-sm font-medium text-text-primary" htmlFor="theme-name">Name</label>
            <Input id="theme-name" onChange={(event) => setName(event.target.value)} value={name} />
          </div>
          <div className="flex shrink-0 gap-2">
            <Button disabled={active} onClick={onSelect} size="sm" variant="secondary">{active ? "Selected" : "Use"}</Button>
            <Button disabled={saveMutation.isPending} size="sm" type="submit">{saveMutation.isPending ? "Saving..." : "Save"}</Button>
            <Button onClick={onDelete} size="sm" variant="danger">Delete</Button>
          </div>
        </div>

        {saveMutation.isError ? <PanelMessage tone="error">{errorMessage(saveMutation.error, "Unable to save theme.")}</PanelMessage> : null}

        {tokenGroups.map((group) => (
          <fieldset className="space-y-3" key={group.label}>
            <legend className="text-xs font-semibold uppercase text-text-secondary">{group.label}</legend>
            <div className="grid gap-3 md:grid-cols-2">
              {themeModes.map((mode) => (
                <div className="space-y-2 rounded border border-border bg-surface-raised p-3" key={mode}>
                  <h3 className="text-sm font-medium capitalize text-text-primary">{mode}</h3>
                  {group.keys.map((key) => (
                    <TokenColorField
                      error={fieldIssue(issues, mode, key)}
                      key={`${mode}-${key}`}
                      mode={mode}
                      name={key}
                      onChange={(value) => changeToken(mode, key, value)}
                      value={tokens[mode][key] ?? ""}
                    />
                  ))}
                </div>
              ))}
            </div>
          </fieldset>
        ))}
      </form>
    </section>
  )
}

function TokenColorField({ error, mode, name, onChange, value }: { error?: string; mode: ThemeMode; name: ThemeTokenKey; onChange: (value: string) => void; value: string }) {
  const label = `${mode} ${name}`
  return (
    <div className="grid gap-1 sm:grid-cols-[minmax(8rem,1fr)_7.5rem] sm:items-center">
      <label className="text-sm text-text-secondary" htmlFor={`${mode}-${name}`}>{name}</label>
      <div className="flex items-center gap-2">
        <Input
          aria-label={`${label} swatch`}
          className="h-9 w-10 shrink-0 cursor-pointer rounded border border-border bg-transparent p-1"
          fullWidth={false}
          onChange={(event) => onChange(event.target.value)}
          type="color"
          value={validHex(value) ? value : "#000000"}
        />
        <Input
          aria-label={`${label} hex`}
          className="font-mono"
          fullWidth={false}
          id={`${mode}-${name}`}
          invalid={Boolean(error)}
          onChange={(event) => onChange(event.target.value)}
          value={value}
        />
      </div>
      {error ? <p className="sm:col-span-2 text-xs text-danger" role="alert">{error}</p> : null}
    </div>
  )
}

function contrastIssuesFrom(error: unknown): ContrastIssue[] {
  if (!(error instanceof ApiError)) return []
  const issues = error.payload?.error?.issues
  return Array.isArray(issues) ? issues.filter((issue): issue is ContrastIssue => typeof issue === "object" && issue != null) : []
}

function fieldIssue(issues: ContrastIssue[], mode: ThemeMode, key: ThemeTokenKey) {
  return issues.find((issue) => issue.mode === mode && issue.foreground === key)?.message
}

function validHex(value: string) {
  return /^#[0-9a-fA-F]{6}$/.test(value)
}

function reorderList<T>(items: T[], from: number, to: number) {
  const next = [...items]
  const [item] = next.splice(from, 1)
  next.splice(to, 0, item)
  return next
}

function nextThemeName(customThemes: ColorTheme[]) {
  const base = "Custom Theme"
  if (!customThemes.some((theme) => theme.name === base)) return base
  let suffix = customThemes.length + 1
  while (customThemes.some((theme) => theme.name === `${base} ${suffix}`)) suffix += 1
  return `${base} ${suffix}`
}

function addThemeToCache(current: ThemesPayload | undefined, theme: ColorTheme): ThemesPayload {
  return { themes: [...(current?.themes ?? []), theme] }
}

function updateThemeInCache(current: ThemesPayload | undefined, theme: ColorTheme): ThemesPayload {
  return { themes: (current?.themes ?? []).map((candidate) => candidate.id === theme.id ? theme : candidate) }
}

function removeThemeFromCache(current: ThemesPayload | undefined, id: number): ThemesPayload {
  return { themes: (current?.themes ?? []).filter((theme) => theme.id !== id) }
}

function replaceCustomThemes(current: ThemesPayload | undefined, customThemes: ColorTheme[]): ThemesPayload {
  const builtIns = (current?.themes ?? []).filter((theme) => theme.built_in)
  return { themes: [...builtIns, ...customThemes] }
}
