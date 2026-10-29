import { useEffect, useMemo, useRef, useState, type CSSProperties, type KeyboardEvent, type ReactNode } from "react"
import { useT } from "../hooks/useT"
import {
  ACCENT_FAMILIES,
  PICKER_TONES,
  accentRamp,
  accentVariant,
  defaultAccentSelection,
  onColor,
  resolveAccentSelection,
  type AccentFamilyId,
  type AccentRef,
  type AccentSelection,
  type AccentShade
} from "../lib/appearance"

const SHADES = [-2, -1, 0, 1, 2] as const
const TONE_BUTTON_CLASS =
  "flex min-h-9 min-w-0 items-center justify-center gap-1 rounded-lg px-1 text-[11px] font-medium focus:outline-none focus-visible:ring-2 focus-visible:ring-brand sm:gap-1.5 sm:text-xs"
const VARIANT_BUTTON_CLASS =
  "h-11 rounded-lg text-sm font-semibold focus:outline-none focus-visible:ring-2 focus-visible:ring-brand focus-visible:ring-offset-2 focus-visible:ring-offset-surface"
const SWATCH_BUTTON_CLASS =
  "h-9 min-w-0 rounded-[10px] focus:outline-none focus-visible:ring-2 focus-visible:ring-brand focus-visible:ring-offset-2 focus-visible:ring-offset-surface"
const SHADE_NAMES: Record<AccentShade, string> = { "-2": "deeper", "-1": "deep", "0": "base", "1": "light", "2": "lighter" }
const SHADE_LABELS: Record<AccentShade, string> = { "-2": "−2", "-1": "−1", "0": "0", "1": "+1", "2": "+2" }
const toneFamilies = PICKER_TONES.map((id) => ACCENT_FAMILIES.find((family) => family.id === id)).filter((family): family is (typeof ACCENT_FAMILIES)[number] =>
  Boolean(family)
)
const naturals = ACCENT_FAMILIES.find((family) => family.id === "earth")!

export type ColorPickerProps = {
  value: string
  accentRef?: AccentRef | null
  onChange: (selection: AccentSelection) => void
  ariaLabel?: string
  name?: string
  initial?: string
  otherAccentHexes?: readonly string[]
  mode?: "light" | "dark"
}

export function ColorPicker({ value, accentRef, onChange, ariaLabel, name = "Syrus", initial, otherAccentHexes, mode = "light" }: ColorPickerProps) {
  const { t } = useT("common")
  const incoming = useMemo(
    () => (value ? resolveAccentSelection(value, accentRef) : defaultAccentSelection(otherAccentHexes)),
    [value, accentRef, otherAccentHexes]
  )
  const [selection, setSelection] = useState(incoming)
  const [activeTone, setActiveTone] = useState<AccentFamilyId>(() => (incoming.accentRef.family === "earth" ? "vivid" : incoming.accentRef.family))
  const toneRefs = useRef<Array<HTMLButtonElement | null>>([])
  const shadeRefs = useRef<Array<HTMLButtonElement | null>>([])

  useEffect(() => {
    setSelection(incoming)
    if (incoming.accentRef.family !== "earth") setActiveTone(incoming.accentRef.family)
  }, [incoming])

  const family = ACCENT_FAMILIES.find((candidate) => candidate.id === selection.accentRef.family)!
  const baseColor = family.colors[selection.accentRef.index]
  const shade = selection.accentRef.shade
  const finalHex = accentVariant(baseColor.hex, shade)
  const ramp = accentRamp(finalHex)
  const selectedTone = selection.accentRef.family === "earth" ? null : selection.accentRef.family
  const previewInitial = initial || name.trim().charAt(0).toUpperCase() || "S"
  const readoutShade = shade === 0 ? "" : ` ${shade > 0 ? "+" : ""}${shade}`

  function choose(nextRef: AccentRef) {
    const nextFamily = ACCENT_FAMILIES.find((item) => item.id === nextRef.family)!
    const next = resolveAccentSelection(accentVariant(nextFamily.colors[nextRef.index].hex, nextRef.shade), nextRef)
    setSelection(next)
    onChange(next)
  }

  function chooseTone(familyId: AccentFamilyId) {
    setActiveTone(familyId)
    choose({ family: familyId, index: selection.accentRef.index, shade })
  }

  return (
    <section aria-label={ariaLabel ?? t("accent_picker.color")} className={mode === "dark" ? "dark" : undefined}>
      <div className="space-y-5 rounded-xl border border-border bg-surface p-4 text-text-primary sm:p-5">
        <div className="flex items-baseline justify-between gap-4">
          <h3 className="text-sm font-semibold">{t("accent_picker.color")}</h3>
          <output aria-live="polite" className="text-right font-mono text-xs text-text-secondary">
            {baseColor.name}
            {readoutShade} · {finalHex}
          </output>
        </div>

        <PickerGroup label={t("accent_picker.tone")}>
          <div className="grid grid-cols-5 rounded-xl bg-surface-inset p-1">
            {toneFamilies.map((tone, index) => {
              const selected = selectedTone === tone.id
              return (
                <button
                  aria-pressed={selected}
                  className={`${TONE_BUTTON_CLASS} ${selected ? "bg-surface shadow-sm" : "text-text-secondary hover:text-text-primary"}`}
                  key={tone.id}
                  onClick={() => chooseTone(tone.id)}
                  onKeyDown={(event) => moveWithinRow(event, toneRefs.current, index, (next) => chooseTone(toneFamilies[next].id))}
                  ref={(node) => {
                    toneRefs.current[index] = node
                  }}
                  tabIndex={selected || (selectedTone == null && index === 0) ? 0 : -1}
                  type="button"
                >
                  <span
                    aria-hidden="true"
                    className="h-3 w-3 shrink-0 rounded-full shadow-[inset_0_0_0_1px_rgba(0,0,0,.08)]"
                    style={{ backgroundColor: tone.colors[selection.accentRef.index].hex }}
                  />
                  <span className="truncate">{t(`accent_picker.families.${tone.id}`)}</span>
                </button>
              )
            })}
          </div>
        </PickerGroup>

        <PickerGroup label={t("accent_picker.hue")}>
          <SwatchRow
            colors={ACCENT_FAMILIES.find((item) => item.id === activeTone)!.colors}
            onSelect={(index) => choose({ family: activeTone, index, shade })}
            selectedIndex={selectedTone ? selection.accentRef.index : null}
          />
        </PickerGroup>

        <PickerGroup label={t("accent_picker.naturals")}>
          <SwatchRow
            colors={naturals.colors}
            onSelect={(index) => choose({ family: "earth", index, shade })}
            selectedIndex={selection.accentRef.family === "earth" ? selection.accentRef.index : null}
          />
        </PickerGroup>

        <PickerGroup label={t("accent_picker.fine_tune")} trailing={t(`accent_picker.variants.${SHADE_NAMES[shade]}`)}>
          <div className="grid grid-cols-5 gap-1.5" role="group">
            {SHADES.map((candidate, index) => {
              const hex = accentVariant(baseColor.hex, candidate)
              const selected = shade === candidate
              return (
                <button
                  aria-label={`${SHADE_LABELS[candidate]} ${t(`accent_picker.variants.${SHADE_NAMES[candidate]}`)}`}
                  aria-pressed={selected}
                  className={VARIANT_BUTTON_CLASS}
                  key={candidate}
                  onClick={() => choose({ ...selection.accentRef, shade: candidate })}
                  onKeyDown={(event) => moveWithinRow(event, shadeRefs.current, index, (next) => choose({ ...selection.accentRef, shade: SHADES[next] }))}
                  ref={(node) => {
                    shadeRefs.current[index] = node
                  }}
                  style={selectionStyle(hex, selected, onColor(hex))}
                  tabIndex={selected ? 0 : -1}
                  type="button"
                >
                  {SHADE_LABELS[candidate]}
                </button>
              )
            })}
          </div>
        </PickerGroup>

        <PickerGroup label={t("accent_picker.preview")}>
          <div className="rounded-[14px] border border-border bg-surface-raised p-4">
            <div className="flex items-start gap-3">
              <div
                className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full text-sm font-semibold"
                style={{ backgroundColor: finalHex, color: onColor(finalHex) }}
              >
                {previewInitial}
              </div>
              <div className="min-w-0 space-y-2">
                <div className="text-xs font-semibold text-text-primary">{name}</div>
                <div className="rounded-xl rounded-tl-sm px-3 py-2 text-sm" style={{ backgroundColor: finalHex, color: onColor(finalHex) }}>
                  {t("accent_picker.preview_message")}
                </div>
                <div className="flex flex-wrap items-center gap-2 text-xs">
                  <span className="rounded-full px-2 py-1 font-medium" style={{ backgroundColor: ramp.tint, color: ramp.ink }}>
                    @{name.split(/\s+/)[0]}
                  </span>
                  <span className="inline-flex items-center gap-1.5 text-text-secondary">
                    <span aria-hidden="true" className="h-2.5 w-2.5 rounded-full" style={{ backgroundColor: finalHex }} />
                    {t("accent_picker.online")}
                  </span>
                </div>
              </div>
            </div>
          </div>
        </PickerGroup>
      </div>
    </section>
  )
}

function PickerGroup({ label, trailing, children }: { label: string; trailing?: string; children: ReactNode }) {
  return (
    <fieldset className="space-y-2">
      <legend className="flex w-full items-center justify-between text-xs font-medium text-text-secondary">
        <span>{label}</span>
        {trailing ? <span>{trailing}</span> : null}
      </legend>
      {children}
    </fieldset>
  )
}

function SwatchRow({
  colors,
  selectedIndex,
  onSelect
}: {
  colors: readonly { name: string; hex: string }[]
  selectedIndex: number | null
  onSelect: (index: number) => void
}) {
  const refs = useRef<Array<HTMLButtonElement | null>>([])

  function move(event: KeyboardEvent<HTMLButtonElement>, index: number) {
    moveWithinRow(event, refs.current, index, onSelect)
  }

  return (
    <div className="grid grid-cols-12 gap-1.5" role="group">
      {colors.map((color, index) => {
        const selected = selectedIndex === index
        return (
          <button
            aria-label={color.name}
            aria-pressed={selected}
            className={SWATCH_BUTTON_CLASS}
            key={color.hex}
            onClick={() => onSelect(index)}
            onKeyDown={(event) => move(event, index)}
            ref={(node) => {
              refs.current[index] = node
            }}
            style={selectionStyle(color.hex, selected)}
            tabIndex={selected || (selectedIndex == null && index === 0) ? 0 : -1}
            type="button"
          />
        )
      })}
    </div>
  )
}

function moveWithinRow(event: KeyboardEvent<HTMLButtonElement>, refs: Array<HTMLButtonElement | null>, index: number, onSelect: (index: number) => void) {
  const delta = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : event.key === "ArrowLeft" || event.key === "ArrowUp" ? -1 : 0
  if (!delta) return
  event.preventDefault()
  const next = (index + delta + refs.length) % refs.length
  refs[next]?.focus()
  onSelect(next)
}

function selectionStyle(backgroundColor: string, selected: boolean, color?: string): CSSProperties {
  return {
    backgroundColor,
    color,
    boxShadow: selected ? "0 0 0 2px var(--color-surface), 0 0 0 4px var(--color-text-primary)" : "inset 0 0 0 1px rgba(0,0,0,.08)"
  }
}
