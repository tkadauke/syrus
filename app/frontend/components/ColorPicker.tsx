import { APPEARANCE_COLORS, type AppearanceMode } from "../lib/appearance"

export function ColorPicker({ value, onChange, mode, ariaLabel }: { value: string; onChange: (key: string) => void; mode: AppearanceMode; ariaLabel: string }) {
  const swatchClass = "h-8 w-8 rounded-full border transition-transform hover:scale-110 focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2"

  return (
    <div aria-label={ariaLabel} className="grid grid-cols-8 gap-2" role="radiogroup">
      {APPEARANCE_COLORS.map((color) => (
        <button
          aria-checked={value === color.key}
          aria-label={color.label}
          className={`${swatchClass} ${value === color.key ? "ring-2 ring-brand ring-offset-2" : "border-border"}`}
          key={color.key}
          onClick={() => onChange(color.key)}
          role="radio"
          style={{ backgroundColor: color[mode] }}
          type="button"
        />
      ))}
    </div>
  )
}
