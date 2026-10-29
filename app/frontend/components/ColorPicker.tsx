import { useT } from "../hooks/useT"
import { ACCENT_FAMILIES, HUE_COLUMNS, PICKER_TONES, type AccentColor } from "../lib/appearance"

const SWATCH_CLASS = "h-8 w-8 rounded-full border transition-transform hover:scale-110 focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2"

export function ColorPicker({ value, onChange, ariaLabel }: { value: string; onChange: (hex: string) => void; ariaLabel: string }) {
  const { t } = useT("common")
  const toneFamilies = PICKER_TONES.map((id) => ACCENT_FAMILIES.find((family) => family.id === id)).filter(
    (family): family is (typeof ACCENT_FAMILIES)[number] => Boolean(family)
  )
  const naturals = ACCENT_FAMILIES.find((family) => family.id === "earth")

  const swatch = (color: AccentColor) => {
    const selected = value.toUpperCase() === color.hex.toUpperCase()
    return (
      <button
        aria-checked={selected}
        aria-label={color.name}
        className={`${SWATCH_CLASS} ${selected ? "ring-2 ring-brand ring-offset-2" : "border-border"}`}
        key={color.hex}
        onClick={() => onChange(color.hex)}
        role="radio"
        style={{ backgroundColor: color.hex }}
        type="button"
      />
    )
  }

  return (
    <div aria-label={ariaLabel} className="overflow-x-auto" role="radiogroup">
      <div className="grid min-w-max grid-cols-[7rem_repeat(12,2rem)] gap-2">
        <div className="text-xs font-medium text-secondary">{t("accent_picker.tone")}</div>
        {HUE_COLUMNS.map((hue) => (
          <div className="text-center text-2xs text-secondary" key={hue}>
            {t(`accent_picker.hues.${hue.toLowerCase()}`)}
          </div>
        ))}

        {toneFamilies.map((family) => (
          <div className="contents" key={family.id}>
            <div className="self-center text-sm font-medium text-primary">{t(`accent_picker.families.${family.id}`)}</div>
            {family.colors.map(swatch)}
          </div>
        ))}

        {naturals ? (
          <div className="contents">
            <div className="self-center text-sm font-medium text-primary">{t("accent_picker.families.earth")}</div>
            {naturals.colors.map(swatch)}
          </div>
        ) : null}
      </div>
    </div>
  )
}
