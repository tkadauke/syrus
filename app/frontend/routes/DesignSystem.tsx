import { useState } from "react"
import type { CSSProperties, ReactNode } from "react"
import { useQuery } from "@tanstack/react-query"
import { useSearchParams } from "react-router-dom"
import { fetchTheme } from "../api/themes"
import { Button } from "../components/Button"
import { Card, Skeleton } from "../components/Card"
import { Checkbox } from "../components/Checkbox"
import { PageHeading, SectionHeading } from "../components/Heading"
import { Input } from "../components/Input"
import { Modal } from "../components/Modal"
import { PanelMessage } from "../components/PanelMessage"
import { Select } from "../components/Select"
import { PILL_TONE_CLASSES, StatusPill, TonePill, type PillTone } from "../components/StatusPill"
import { Toggle } from "../components/Toggle"
import { useTheme } from "../contexts/ThemeContext"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { useColorTokens } from "../lib/colorTokens"

const TOKEN_SPECS: { key: string; cssVar: string }[] = [
  { key: "brand", cssVar: "--color-brand" },
  { key: "brand-emphasis", cssVar: "--color-brand-emphasis" },
  { key: "surface", cssVar: "--color-surface" },
  { key: "surface-raised", cssVar: "--color-surface-raised" },
  { key: "border", cssVar: "--color-border" },
  { key: "text-primary", cssVar: "--color-text-primary" },
  { key: "text-secondary", cssVar: "--color-text-secondary" },
  { key: "success", cssVar: "--color-success" },
  { key: "warning", cssVar: "--color-warning" },
  { key: "danger", cssVar: "--color-danger" },
  { key: "info", cssVar: "--color-info" },
  { key: "neutral", cssVar: "--color-neutral" },
  { key: "on-brand", cssVar: "--color-on-brand" }
]

const STATUS_PILL_EXAMPLE_STATES = ["queued", "running", "succeeded", "failed", "cancelled"]

export function DesignSystemRoute() {
  const { t } = useT("settings")
  usePageTitle(t("design_system.heading"))
  const { resolvedTheme } = useTheme()
  const [searchParams] = useSearchParams()
  const themeIdParam = searchParams.get("theme_id")
  const themeId = themeIdParam ? Number(themeIdParam) : null

  const previewQuery = useQuery({
    queryKey: ["design-system-theme-preview", themeId],
    queryFn: () => fetchTheme(themeId as number),
    enabled: themeId != null && Number.isFinite(themeId),
    retry: false
  })

  const previewTheme = previewQuery.data?.theme ?? null
  // Applied on this page's own root <main> only (via inline style below) --
  // never on document.documentElement -- so a draft theme preview can never
  // leak into the surrounding app chrome, sidebar, or other open tabs.
  const previewTokens = previewTheme ? previewTheme.tokens[resolvedTheme] : null
  const previewStyle = previewTokens
    ? (Object.fromEntries(Object.entries(previewTokens).map(([key, value]) => [`--color-${key}`, value])) as CSSProperties)
    : undefined

  const liveTokenValues = useColorTokens(TOKEN_SPECS.map((spec) => spec.cssVar))
  const tokenValues = previewTokens
    ? TOKEN_SPECS.map((spec) => previewTokens[spec.key] ?? "")
    : liveTokenValues

  const [checked, setChecked] = useState(true)
  const [toggleOn, setToggleOn] = useState(true)
  const [modalOpen, setModalOpen] = useState(false)

  return (
    <main aria-label={t("aria_design_system")} className="mx-auto max-w-5xl space-y-10 p-6" data-design-system-preview={previewTheme?.slug} style={previewStyle}>
      <header>
        <PageHeading>{t("design_system.heading")}</PageHeading>
        <p className="mt-1 text-sm text-text-secondary">{t("design_system.description")}</p>
      </header>

      {themeId != null && previewTheme ? (
        <PanelMessage tone="success">{t("design_system.preview_banner", { name: previewTheme.name })}</PanelMessage>
      ) : null}
      {themeId != null && previewQuery.isError ? (
        <PanelMessage tone="error">{t("design_system.preview_not_found")}</PanelMessage>
      ) : null}

      <TokenSwatchesSection tokenValues={tokenValues} />
      <ButtonsSection />
      <FormControlsSection checked={checked} onCheckedChange={setChecked} onToggleChange={setToggleOn} toggleOn={toggleOn} />
      <CardsSection />
      <ModalSection onClose={() => setModalOpen(false)} onOpen={() => setModalOpen(true)} open={modalOpen} />
      <StatusPillsSection />
      <HeadingsSection />
    </main>
  )
}

function TokenSwatchesSection({ tokenValues }: { tokenValues: string[] }) {
  const { t } = useT("settings")

  return (
    <section>
      <SectionHeading>{t("design_system.tokens.heading")}</SectionHeading>
      <p className="mt-1 text-sm text-text-secondary">{t("design_system.tokens.description")}</p>
      <div className="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
        {TOKEN_SPECS.map((spec, index) => (
          <div className="flex items-center gap-3 rounded border border-border bg-surface p-3" key={spec.key}>
            <span aria-hidden="true" className="h-8 w-8 shrink-0 rounded border border-border" style={{ backgroundColor: tokenValues[index] || undefined }} />
            <div className="min-w-0">
              <div className="truncate text-sm font-medium text-text-primary">{spec.key}</div>
              <div className="truncate text-xs text-text-secondary">{tokenValues[index] || "—"}</div>
            </div>
          </div>
        ))}
      </div>
    </section>
  )
}

function ButtonsSection() {
  const { t } = useT("settings")

  return (
    <section>
      <SectionHeading>{t("design_system.buttons.heading")}</SectionHeading>
      <p className="mt-1 text-sm text-text-secondary">{t("design_system.buttons.description")}</p>
      <div className="mt-4 flex flex-wrap items-center gap-3">
        <Button variant="primary">{t("design_system.buttons.primary")}</Button>
        <Button variant="secondary">{t("design_system.buttons.secondary")}</Button>
        <Button variant="danger">{t("design_system.buttons.danger")}</Button>
        <Button variant="success">{t("design_system.buttons.success")}</Button>
      </div>
      <div className="mt-3 flex flex-wrap items-center gap-3">
        <Button size="sm" variant="primary">{t("design_system.buttons.primary")}</Button>
        <Button size="sm" variant="secondary">{t("design_system.buttons.secondary")}</Button>
        <Button disabled variant="primary">{t("design_system.buttons.disabled")}</Button>
      </div>
    </section>
  )
}

function FormControlsSection({ checked, onCheckedChange, toggleOn, onToggleChange }: {
  checked: boolean
  onCheckedChange: (checked: boolean) => void
  toggleOn: boolean
  onToggleChange: (checked: boolean) => void
}) {
  const { t } = useT("settings")

  return (
    <section>
      <SectionHeading>{t("design_system.form.heading")}</SectionHeading>
      <p className="mt-1 text-sm text-text-secondary">{t("design_system.form.description")}</p>
      <div className="mt-4 grid gap-4 sm:grid-cols-2">
        <Field label={t("design_system.form.input_label")}>
          <Input placeholder={t("design_system.form.input_placeholder")} />
        </Field>
        <Field label={t("design_system.form.input_invalid_label")}>
          <Input defaultValue={t("design_system.form.input_invalid_value")} invalid />
        </Field>
        <Field label={t("design_system.form.select_label")}>
          <Select defaultValue="light">
            <option value="light">Light</option>
            <option value="dark">Dark</option>
            <option value="system">System</option>
          </Select>
        </Field>
        <div className="flex flex-col justify-center gap-3">
          <Checkbox checked={checked} label={t("design_system.form.checkbox_label")} onChange={(event) => onCheckedChange(event.target.checked)} />
          <Toggle checked={toggleOn} label={t("design_system.form.toggle_label")} onChange={onToggleChange} />
        </div>
      </div>
    </section>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block text-sm font-medium text-text-primary">
      {label}
      <div className="mt-2">{children}</div>
    </label>
  )
}

function CardsSection() {
  const { t } = useT("settings")

  return (
    <section>
      <SectionHeading>{t("design_system.cards.heading")}</SectionHeading>
      <p className="mt-1 text-sm text-text-secondary">{t("design_system.cards.description")}</p>
      <div className="mt-4 flex flex-wrap gap-4">
        <Card>
          <SectionHeading as="h3">{t("design_system.cards.base_title")}</SectionHeading>
          <p className="mt-1 text-sm text-text-secondary">{t("design_system.cards.base_body")}</p>
        </Card>
        <Card variant="preview">
          <SectionHeading as="h3">{t("design_system.cards.preview_title")}</SectionHeading>
          <p className="mt-1 text-sm text-text-secondary">{t("design_system.cards.base_body")}</p>
        </Card>
        <Card compact variant="preview">
          <Skeleton className="h-4 w-3/4" />
          <Skeleton className="mt-2 h-4 w-1/2" />
        </Card>
      </div>
    </section>
  )
}

function ModalSection({ open, onOpen, onClose }: { open: boolean; onOpen: () => void; onClose: () => void }) {
  const { t } = useT("settings")

  return (
    <section>
      <SectionHeading>{t("design_system.modal.heading")}</SectionHeading>
      <p className="mt-1 text-sm text-text-secondary">{t("design_system.modal.description")}</p>
      <div className="mt-4">
        <Button onClick={onOpen}>{t("design_system.modal.open")}</Button>
      </div>
      <Modal label={t("design_system.modal.title")} onClose={onClose} open={open}>
        <SectionHeading as="h3">{t("design_system.modal.title")}</SectionHeading>
        <p className="mt-2 text-sm text-text-secondary">{t("design_system.modal.body")}</p>
        <div className="mt-4 flex justify-end">
          <Button onClick={onClose} variant="secondary">{t("design_system.modal.close")}</Button>
        </div>
      </Modal>
    </section>
  )
}

function StatusPillsSection() {
  const { t } = useT("settings")
  const tones = Object.keys(PILL_TONE_CLASSES) as PillTone[]

  return (
    <section>
      <SectionHeading>{t("design_system.status.heading")}</SectionHeading>
      <p className="mt-1 text-sm text-text-secondary">{t("design_system.status.description")}</p>
      <SectionHeading as="h3" className="mt-4 text-sm">{t("design_system.status.tones_heading")}</SectionHeading>
      <div className="mt-2 flex flex-wrap gap-2">
        {tones.map((tone) => (
          <TonePill key={tone} tone={tone}>{tone}</TonePill>
        ))}
      </div>
      <SectionHeading as="h3" className="mt-4 text-sm">{t("design_system.status.states_heading")}</SectionHeading>
      <div className="mt-2 flex flex-wrap gap-2">
        {STATUS_PILL_EXAMPLE_STATES.map((state) => (
          <StatusPill key={state} state={state} />
        ))}
      </div>
    </section>
  )
}

function HeadingsSection() {
  const { t } = useT("settings")

  return (
    <section>
      <SectionHeading>{t("design_system.headings.heading")}</SectionHeading>
      <p className="mt-1 text-sm text-text-secondary">{t("design_system.headings.description")}</p>
      <div className="mt-4 space-y-3 rounded border border-border bg-surface p-4">
        <PageHeading>{t("design_system.headings.page_example")}</PageHeading>
        <SectionHeading>{t("design_system.headings.section_example")}</SectionHeading>
        <SectionHeading as="h3">{t("design_system.headings.subsection_example")}</SectionHeading>
      </div>
    </section>
  )
}
