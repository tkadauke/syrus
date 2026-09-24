import { useMutation, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { patchReviewDiffSettings, type ReviewDiffSettings } from "../../api/reviewDiffSettings"
import { Button } from "../../components/Button"
import { Checkbox } from "../../components/Checkbox"
import { Input } from "../../components/Input"
import { Modal } from "../../components/Modal"
import { Select } from "../../components/Select"
import { useT } from "../../hooks/useT"

export function ReviewDiffSettingsModal({ initialSettings, onClose }: { initialSettings: ReviewDiffSettings; onClose: () => void }) {
  const queryClient = useQueryClient()
  const { t } = useT("jobs")
  const [settings, setSettings] = useState(initialSettings)
  const mutation = useMutation({
    mutationFn: patchReviewDiffSettings,
    onSuccess: (payload) => {
      setSettings(payload.review_diff_settings)
      queryClient.setQueryData(["review_diff_settings"], payload)
    }
  })

  function updateSetting<Key extends keyof ReviewDiffSettings>(key: Key, value: ReviewDiffSettings[Key]) {
    const next = { ...settings, [key]: value }
    setSettings(next)
    mutation.mutate({ [key]: value })
  }

  return (
    <Modal className="w-full max-w-3xl rounded-[var(--radius-panel)] bg-surface p-5 shadow-[var(--shadow-panel)]" label={t("review_settings_title")} onClose={onClose} open>
      <div className="mb-4 flex items-center justify-between gap-3">
        <h2 className="text-lg font-semibold text-text-primary">{t("review_settings_title")}</h2>
        <Button onClick={onClose} size="sm" variant="secondary">{t("review_settings_close")}</Button>
      </div>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <SettingsSelect label={t("review_settings_line_wrapping")} onChange={(value) => updateSetting("line_wrapping", value as ReviewDiffSettings["line_wrapping"])} options={[["wrap", t("review_settings_wrap")], ["scroll", t("review_settings_scroll")]]} value={settings.line_wrapping} />
        <SettingsSelect label={t("review_settings_desktop_view")} onChange={(value) => updateSetting("desktop_view", value as ReviewDiffSettings["desktop_view"])} options={[["unified", t("review_settings_unified")], ["split", t("review_settings_split")]]} value={settings.desktop_view} />
        <SettingsSelect label={t("review_settings_intraline")} onChange={(value) => updateSetting("intraline_highlighting", value as ReviewDiffSettings["intraline_highlighting"])} options={[["word", t("review_settings_word")], ["off", t("review_settings_off")]]} value={settings.intraline_highlighting} />
        <SettingsSelect label={t("review_settings_whitespace")} onChange={(value) => updateSetting("whitespace", value as ReviewDiffSettings["whitespace"])} options={[["show", t("review_settings_show")], ["trim_trailing", t("review_settings_trim_trailing")]]} value={settings.whitespace} />
        <SettingsSelect label={t("review_settings_density")} onChange={(value) => updateSetting("density", value as ReviewDiffSettings["density"])} options={[["compact", t("review_settings_compact")], ["comfortable", t("review_settings_comfortable")], ["spacious", t("review_settings_spacious")]]} value={settings.density} />
        <label className="space-y-1 text-sm text-text-secondary">
          <span>{t("review_settings_tab_width")}</span>
          <Input max={8} min={2} onChange={(event) => updateSetting("tab_width", Number(event.target.value))} type="number" value={settings.tab_width} />
        </label>
        <SettingsCheckbox checked={settings.syntax_highlighting} label={t("review_settings_syntax")} onChange={(checked) => updateSetting("syntax_highlighting", checked)} />
        <SettingsCheckbox checked={settings.line_numbers} label={t("review_settings_line_numbers")} onChange={(checked) => updateSetting("line_numbers", checked)} />
        <SettingsCheckbox checked={settings.file_list} label={t("review_settings_file_list")} onChange={(checked) => updateSetting("file_list", checked)} />
      </div>
      {mutation.isError ? <p className="mt-3 text-sm text-danger-text">{t("review_settings_save_error")}</p> : null}
    </Modal>
  )
}

function SettingsSelect({ label, onChange, options, value }: { label: string; onChange: (value: string) => void; options: Array<[string, string]>; value: string }) {
  return (
    <label className="space-y-1 text-sm text-text-secondary">
      <span>{label}</span>
      <Select className="w-full" onChange={(event) => onChange(event.target.value)} value={value}>
        {options.map(([optionValue, optionLabel]) => <option key={optionValue} value={optionValue}>{optionLabel}</option>)}
      </Select>
    </label>
  )
}

function SettingsCheckbox({ checked, label, onChange }: { checked: boolean; label: string; onChange: (checked: boolean) => void }) {
  return (
    <div className="flex items-center gap-2 rounded border border-border px-3 py-2 text-sm text-text-primary">
      <Checkbox checked={checked} label={label} onChange={(event) => onChange(event.target.checked)} />
    </div>
  )
}
