import { Input } from "../Input"
import { Select } from "../Select"
import { useT } from "../../hooks/useT"
import type { FilterChip, FilterSchemaField } from "./types"
import { filterLabelClass, isObjectValue } from "./helpers"

const UNITS = ["minutes", "hours", "days", "weeks", "months"] as const

type Preset = {
  key: string
  label: string
  build: (precision: "date" | "datetime", now: Date) => Pick<FilterChip, "op" | "value">
}

const PRESETS: Preset[] = [
  { key: "today", label: "Today", build: (precision, now) => rangePreset(precision, startOfDay(now), endOfDay(now)) },
  { key: "yesterday", label: "Yesterday", build: (precision, now) => rangePreset(precision, shiftDays(startOfDay(now), -1), shiftDays(endOfDay(now), -1)) },
  { key: "last_24_hours", label: "Last 24 hours", build: () => ({ op: "within_last", value: { n: 24, unit: "hours" } }) },
  { key: "last_7_days", label: "Last 7 days", build: () => ({ op: "within_last", value: { n: 7, unit: "days" } }) },
  { key: "last_30_days", label: "Last 30 days", build: () => ({ op: "within_last", value: { n: 30, unit: "days" } }) },
  { key: "this_week", label: "This week", build: (precision, now) => rangePreset(precision, startOfWeek(now), endOfDay(now)) },
  { key: "this_month", label: "This month", build: (precision, now) => rangePreset(precision, startOfMonth(now), endOfDay(now)) }
]

export function DateTimeRangeFilterValueEditor({ chip, meta, onChange }: { chip: FilterChip; meta: FilterSchemaField; onChange: (chip: FilterChip) => void }) {
  const { t } = useT("nav")
  const precision = meta.date_precision === "date" ? "date" : "datetime"
  const inputType = precision === "datetime" ? "datetime-local" : "date"

  function applyPreset(preset: Preset) {
    onChange({ field: chip.field, ...preset.build(precision, new Date()) })
  }

  return (
    <div className="space-y-3">
      <div>
        <div className={filterLabelClass()}>{t("filter_bar.presets", { defaultValue: "Presets" })}</div>
        <div className="mt-1 flex flex-wrap gap-1.5">
          {PRESETS.map((preset) => (
            <button
              className="rounded border border-gray-300 px-2 py-1 text-xs font-medium normal-case text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
              key={preset.key}
              onClick={() => applyPreset(preset)}
              type="button"
            >
              {t(`filter_bar.date_preset.${preset.key}`, { defaultValue: preset.label })}
            </button>
          ))}
        </div>
      </div>
      {chip.op === "within_last" || chip.op === "more_than_ago" ? (
        <RelativeDateControls chip={chip} onChange={onChange} />
      ) : chip.op === "between" ? (
        <BetweenDateControls chip={chip} inputType={inputType} onChange={onChange} precision={precision} />
      ) : (
        <SingleDateControl chip={chip} inputType={inputType} onChange={onChange} precision={precision} />
      )}
    </div>
  )
}

function RelativeDateControls({ chip, onChange }: { chip: FilterChip; onChange: (chip: FilterChip) => void }) {
  const { t } = useT("nav")
  const value = isObjectValue(chip.value) ? chip.value : { n: 7, unit: "days" }

  return (
    <div className="flex flex-wrap items-end gap-2">
      <label className={filterLabelClass()} htmlFor="filter-date-amount">
        {t("filter_bar.amount")}
        <Input className="mt-1 w-20" fullWidth={false} id="filter-date-amount" min="0" onChange={(event) => onChange({ ...chip, value: { ...value, n: Number(event.target.value || 0) } })} type="number" value={Number(value.n || 0)} />
      </label>
      <label className={filterLabelClass()} htmlFor="filter-date-unit">
        {t("filter_bar.unit")}
        <Select className="mt-1" fullWidth={false} id="filter-date-unit" onChange={(event) => onChange({ ...chip, value: { ...value, unit: event.target.value } })} value={String(value.unit || "days")}>
          {UNITS.map((unit) => <option key={unit} value={unit}>{t(`filter_bar.time_unit.${unit}`)}</option>)}
        </Select>
      </label>
    </div>
  )
}

function BetweenDateControls({ chip, inputType, onChange, precision }: { chip: FilterChip; inputType: "date" | "datetime-local"; onChange: (chip: FilterChip) => void; precision: "date" | "datetime" }) {
  const { t } = useT("nav")
  const value = Array.isArray(chip.value) ? chip.value : ["", ""]

  return (
    <div className="flex flex-wrap items-end gap-2">
      <label className={filterLabelClass()} htmlFor="filter-date-from">
        {t("filter_bar.from")}
        <Input className="mt-1" fullWidth={false} id="filter-date-from" onChange={(event) => onChange({ ...chip, value: [event.target.value, value[1] || ""] })} type={inputType} value={inputValue(value[0], precision)} />
      </label>
      <label className={filterLabelClass()} htmlFor="filter-date-to">
        {t("filter_bar.to")}
        <Input className="mt-1" fullWidth={false} id="filter-date-to" onChange={(event) => onChange({ ...chip, value: [value[0] || "", event.target.value] })} type={inputType} value={inputValue(value[1], precision)} />
      </label>
    </div>
  )
}

function SingleDateControl({ chip, inputType, onChange, precision }: { chip: FilterChip; inputType: "date" | "datetime-local"; onChange: (chip: FilterChip) => void; precision: "date" | "datetime" }) {
  const { t } = useT("nav")

  return (
    <label className={filterLabelClass()} htmlFor="filter-date-value">
      {t("filter_bar.value")}
      <Input className="mt-1" fullWidth={false} id="filter-date-value" onChange={(event) => onChange({ ...chip, value: event.target.value })} type={inputType} value={inputValue(chip.value, precision)} />
    </label>
  )
}

function rangePreset(precision: "date" | "datetime", from: Date, to: Date) {
  return { op: "between", value: [serializeDate(from, precision), serializeDate(to, precision)] }
}

function inputValue(value: unknown, precision: "date" | "datetime") {
  const raw = String(value ?? "")
  return precision === "datetime" ? raw.replace(/Z$/, "").slice(0, 16) : raw.slice(0, 10)
}

function serializeDate(date: Date, precision: "date" | "datetime") {
  const yyyy = String(date.getFullYear()).padStart(4, "0")
  const mm = String(date.getMonth() + 1).padStart(2, "0")
  const dd = String(date.getDate()).padStart(2, "0")
  if (precision === "date") return `${yyyy}-${mm}-${dd}`

  const hh = String(date.getHours()).padStart(2, "0")
  const min = String(date.getMinutes()).padStart(2, "0")
  return `${yyyy}-${mm}-${dd}T${hh}:${min}`
}

function startOfDay(date: Date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, 0)
}

function endOfDay(date: Date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(), 23, 59)
}

function shiftDays(date: Date, days: number) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days, date.getHours(), date.getMinutes())
}

function startOfWeek(date: Date) {
  const day = date.getDay()
  const offset = day === 0 ? -6 : 1 - day
  return shiftDays(startOfDay(date), offset)
}

function startOfMonth(date: Date) {
  return new Date(date.getFullYear(), date.getMonth(), 1, 0, 0)
}
