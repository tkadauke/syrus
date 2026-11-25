import { Input } from "./Input"
import { useT } from "../hooks/useT"

export const QUESTION_EAGERNESS_LEVELS = ["autonomous", "independent", "balanced", "collaborative", "inquisitive"] as const
export type QuestionEagerness = (typeof QUESTION_EAGERNESS_LEVELS)[number]

export function QuestionEagernessFields({
  eagerness,
  timeoutSeconds,
  onChange,
  showTimeout = true
}: {
  eagerness: QuestionEagerness | null
  timeoutSeconds: number | null
  onChange: (eagerness: QuestionEagerness | null, timeoutSeconds: number | null) => void
  showTimeout?: boolean
}) {
  const { t } = useT("settings")
  const value = eagerness == null ? 0 : QUESTION_EAGERNESS_LEVELS.indexOf(eagerness) + 1
  const effective = eagerness || "balanced"
  return (
    <fieldset className="space-y-3">
      <legend className="font-medium text-text">{t("question_eagerness.title")}</legend>
      <Input
        aria-label={t("question_eagerness.slider")}
        className="w-full accent-brand"
        max={5}
        min={0}
        onChange={(event) => {
          const index = Number(event.target.value)
          onChange(index === 0 ? null : QUESTION_EAGERNESS_LEVELS[index - 1], timeoutSeconds)
        }}
        step={1}
        type="range"
        value={value}
      />
      <div className="flex justify-between text-xs text-text-muted">
        <span>{t("question_eagerness.inherit")}</span>
        <span>{t(`question_eagerness.levels.${effective}.label`)}</span>
      </div>
      <p className="text-sm text-text-secondary">{t(`question_eagerness.levels.${effective}.description`)}</p>
      {showTimeout ? (
        <>
          <label className="block text-sm font-medium text-text">
            {t("question_eagerness.timeout")}
            <Input
              className="mt-1 w-40"
              min={1}
              onChange={(event) => onChange(eagerness, event.target.value ? Number(event.target.value) * 60 : null)}
              type="number"
              value={timeoutSeconds == null ? "" : timeoutSeconds / 60}
            />
          </label>
          <p className="text-xs text-text-muted">{t("question_eagerness.timeout_help")}</p>
        </>
      ) : null}
    </fieldset>
  )
}
