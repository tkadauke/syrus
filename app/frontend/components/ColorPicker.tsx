import { ACCENT_COLORS } from "../lib/appearance"

export function ColorPicker({ value, onChange, ariaLabel }: { value: string; onChange: (hex: string) => void; ariaLabel: string }) {
  const swatchClass = "h-8 w-8 rounded-full border transition-transform hover:scale-110 focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2"

  return (
    <div aria-label={ariaLabel} className="grid grid-cols-8 gap-2" role="radiogroup">
      {ACCENT_COLORS.map((color) => (
        <button
          aria-checked={value.toUpperCase() === color.hex.toUpperCase()}
          aria-label={color.name}
          className={`${swatchClass} ${value.toUpperCase() === color.hex.toUpperCase() ? "ring-2 ring-brand ring-offset-2" : "border-border"}`}
          key={color.hex}
          onClick={() => onChange(color.hex)}
          role="radio"
          style={{ backgroundColor: color.hex }}
          type="button"
        />
      ))}
    </div>
  )
}
