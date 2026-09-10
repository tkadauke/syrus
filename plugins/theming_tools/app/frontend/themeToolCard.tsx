import type { ReactNode } from "react"
import { isPlainObject, type ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, Row, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"

export type ThemeTokens = Record<string, string>

export type ThemePayload = {
  id: string
  slug: string | null
  name: string
  builtIn: boolean | null
  position: string | null
  tokens: Record<string, ThemeTokens>
  warnings: string[]
}

const TOKEN_ORDER = [
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
]

function stringTokens(value: unknown): ThemeTokens | null {
  if (!isPlainObject(value)) return null

  const entries = Object.entries(value).flatMap(([key, rawValue]) => {
    const color = displayValue(rawValue)
    return color ? [[key, color] as const] : []
  })
  return entries.length > 0 ? Object.fromEntries(entries) : null
}

function parseTokens(value: unknown): Record<string, ThemeTokens> {
  if (!isPlainObject(value)) return {}

  return Object.fromEntries(
    Object.entries(value).flatMap(([mode, modeTokens]) => {
      const tokens = stringTokens(modeTokens)
      return tokens ? [[mode, tokens] as const] : []
    })
  )
}

export function parseTheme(value: unknown): ThemePayload | null {
  if (!isPlainObject(value)) return null

  const id = displayValue(value.id) ?? displayValue(value.theme_id)
  const name = displayValue(value.name)
  if (!id || !name) return null

  const warnings = Array.isArray(value.contrast_warnings)
    ? value.contrast_warnings.flatMap((warning) => {
      const text = displayValue(warning)
      return text ? [text] : []
    })
    : []

  return {
    id,
    slug: displayValue(value.slug),
    name,
    builtIn: typeof value.built_in === "boolean" ? value.built_in : null,
    position: displayValue(value.position),
    tokens: parseTokens(value.tokens),
    warnings
  }
}

export function parseThemeResult(context: ToolCardContext): ThemePayload | null {
  return parseTheme(context.parsedResult)
}

export function themeRows(context: ToolCardContext): ThemePayload[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.themes)) return null

  return parsed.themes.flatMap((entry) => {
    const theme = parseTheme(entry)
    return theme ? [theme] : []
  })
}

export function themeListSummary(context: ToolCardContext): string | null {
  const rows = themeRows(context)
  if (!rows) return null

  return `${rows.length} theme${rows.length === 1 ? "" : "s"}`
}

function ErrorCard({ action, context }: { action: string; context: ToolCardContext }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state="error" tone="failure" />
        <span className="font-medium text-gray-900 dark:text-gray-100">{action} failed</span>
      </div>
      <div className="whitespace-pre-wrap break-words text-gray-700 dark:text-gray-300">{context.resultBody}</div>
    </CardShell>
  )
}

export function errorSummary(action: string, context: ToolCardContext): string | null {
  return context.resultError ? `${action} failed` : null
}

export function renderError(action: string, context: ToolCardContext): ReactNode | null {
  return context.resultError ? <ErrorCard action={action} context={context} /> : null
}

function ThemeHeader({ theme, outcome }: { theme: ThemePayload; outcome: string }) {
  return (
    <div className="flex flex-wrap items-center gap-2">
      <StatePill state={outcome} tone={outcome === "preview" ? "info" : "success"} />
      <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">#{theme.id}</span>
      {theme.builtIn === true ? <Badge>built in</Badge> : theme.builtIn === false ? <Badge>custom</Badge> : null}
      {theme.slug ? <Badge>{theme.slug}</Badge> : null}
    </div>
  )
}

function Swatch({ name, color }: { name: string; color: string }) {
  return (
    <div className="flex min-w-0 items-center gap-1.5">
      <span
        aria-label={`${name} ${color}`}
        className="h-4 w-4 shrink-0 rounded border border-black/10 dark:border-white/20"
        style={{ backgroundColor: color }}
      />
      <span className="truncate font-mono text-2xs text-gray-600 dark:text-gray-300" title={`${name}: ${color}`}>
        {name}
      </span>
    </div>
  )
}

function ModeSwatches({ mode, tokens }: { mode: string; tokens: ThemeTokens }) {
  const orderedEntries = TOKEN_ORDER.flatMap((key) => tokens[key] ? [[key, tokens[key]] as const] : [])
  const extraEntries = Object.entries(tokens).filter(([key]) => !TOKEN_ORDER.includes(key))
  const entries = [...orderedEntries, ...extraEntries]

  if (entries.length === 0) return null

  return (
    <div>
      <SectionLabel>{mode}</SectionLabel>
      <div className="mt-1 grid grid-cols-2 gap-1 sm:grid-cols-3">
        {entries.slice(0, 13).map(([key, color]) => <Swatch color={color} key={`${mode}-${key}`} name={key} />)}
      </div>
    </div>
  )
}

export function ThemeCard({ theme, outcome }: { theme: ThemePayload; outcome: string }) {
  const tokenEntries = Object.entries(theme.tokens)

  return (
    <CardShell>
      <ThemeHeader outcome={outcome} theme={theme} />
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{theme.name}</div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Theme ID" value={theme.id} />
        {theme.position ? <Row label="Position" value={theme.position} /> : null}
      </dl>
      {tokenEntries.length > 0 ? (
        <div className="grid gap-2 sm:grid-cols-2">
          {tokenEntries.map(([mode, tokens]) => <ModeSwatches key={mode} mode={mode} tokens={tokens} />)}
        </div>
      ) : null}
      {theme.warnings.length > 0 ? (
        <div>
          <SectionLabel>Contrast warnings</SectionLabel>
          <ul className="mt-1 list-disc space-y-1 pl-4 text-gray-700 dark:text-gray-300">
            {theme.warnings.map((warning, index) => <li key={`${warning}-${index}`}>{warning}</li>)}
          </ul>
        </div>
      ) : null}
    </CardShell>
  )
}

export function MalformedThemeCard({ action }: { action: string }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state="unreadable" tone="warning" />
        <span className="font-medium text-gray-900 dark:text-gray-100">{action} returned an unexpected theme payload.</span>
      </div>
    </CardShell>
  )
}

export function ThemeListBody({ rows }: { rows: ThemePayload[] }) {
  if (rows.length === 0) return <EmptyState>No custom themes yet.</EmptyState>

  return (
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">Theme</th>
            <th className="px-2 py-1 font-semibold" scope="col">Status</th>
            <th className="px-2 py-1 font-semibold" scope="col">Palette</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((theme) => (
            <tr key={theme.id}>
              <td className="px-2 py-1">
                <div className="font-medium text-gray-900 dark:text-gray-100">{theme.name}</div>
                <div className="font-mono text-2xs text-gray-500 dark:text-gray-400">#{theme.id}{theme.slug ? ` · ${theme.slug}` : ""}</div>
              </td>
              <td className="whitespace-nowrap px-2 py-1">
                {theme.builtIn === true ? <StatePill state="built in" tone="neutral" /> : <StatePill state="custom" tone="info" />}
              </td>
              <td className="min-w-[12rem] px-2 py-1">
                <div className="flex flex-wrap gap-1">
                  {Object.entries(theme.tokens.light ?? {}).slice(0, 6).map(([key, color]) => (
                    <span
                      aria-label={`${theme.name} ${key} ${color}`}
                      className="h-4 w-4 rounded border border-black/10 dark:border-white/20"
                      key={`${theme.id}-${key}`}
                      style={{ backgroundColor: color }}
                      title={`${key}: ${color}`}
                    />
                  ))}
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

export type DeleteThemeOutcome = { deletedThemeId: string; fallbackThemeId: string | null }

export function parseDeleteOutcome(context: ToolCardContext): DeleteThemeOutcome | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const deletedThemeId = displayValue(parsed.deleted_theme_id)
  if (!deletedThemeId) return null

  return {
    deletedThemeId,
    fallbackThemeId: displayValue(parsed.fallback_theme_id)
  }
}

export function DeleteThemeCard({ outcome }: { outcome: DeleteThemeOutcome }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state="deleted" tone="success" />
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">#{outcome.deletedThemeId}</span>
      </div>
      {outcome.fallbackThemeId ? <Row label="Fallback active theme" value={`#${outcome.fallbackThemeId}`} /> : null}
    </CardShell>
  )
}
