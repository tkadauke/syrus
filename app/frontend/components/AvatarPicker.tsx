import { BUNDLED_AVATARS } from "../lib/appearance"

export function AvatarPicker({ value, onChange, ariaLabel }: { value: string | null; onChange: (key: string) => void; ariaLabel: string }) {
  return (
    <div aria-label={ariaLabel} className="grid grid-cols-4 gap-3" role="radiogroup">
      {BUNDLED_AVATARS.map((avatar) => (
        <button
          aria-checked={value === avatar.key}
          aria-label={avatar.label}
          className={`rounded-full focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2 ${value === avatar.key ? "ring-2 ring-brand ring-offset-2" : ""}`}
          key={avatar.key}
          onClick={() => onChange(avatar.key)}
          role="radio"
          type="button"
        >
          <img alt="" className="h-14 w-14 rounded-full object-cover ring-1 ring-border" src={avatar.url} />
        </button>
      ))}
    </div>
  )
}
