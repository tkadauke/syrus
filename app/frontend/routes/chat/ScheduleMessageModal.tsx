import { useEffect, useRef, useState, type FormEvent } from "react"
import { parseScheduleTime } from "../../lib/scheduleTime"
import { primaryButton, secondaryButton } from "./utils"

export function ScheduleMessageModal({
  initialTime = "",
  initialBody = "",
  submitting = false,
  onCancel,
  onSchedule
}: {
  initialTime?: string
  initialBody?: string
  submitting?: boolean
  onCancel: () => void
  onSchedule: (input: { fireAt: Date; body: string }) => void
}) {
  const [timeText, setTimeText] = useState(initialTime)
  const [body, setBody] = useState(initialBody)
  const [error, setError] = useState<string | null>(null)
  const timeRef = useRef<HTMLInputElement | null>(null)

  useEffect(() => {
    timeRef.current?.focus()

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onCancel()
    }

    document.addEventListener("keydown", handleKeyDown)
    return () => document.removeEventListener("keydown", handleKeyDown)
  }, [onCancel])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const fireAt = parseScheduleTime(timeText)
    const trimmedBody = body.trim()

    if (!fireAt) {
      setError("Enter a time like 30m, 2h, tomorrow 9am, or 14:30.")
      return
    }

    if (!trimmedBody) {
      setError("Message cannot be blank.")
      return
    }

    setError(null)
    onSchedule({ fireAt, body: trimmedBody })
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" onClick={onCancel} role="presentation">
      <section
        aria-labelledby="schedule-message-title"
        aria-modal="true"
        className="w-full max-w-md rounded border border-gray-200 bg-white p-4 shadow-xl dark:border-gray-700 dark:bg-gray-900"
        onClick={(event) => event.stopPropagation()}
        role="dialog"
      >
        <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100" id="schedule-message-title">Schedule Message</h2>
        <form className="mt-4 space-y-4" onSubmit={submit}>
          <label className="block">
            <span className="text-sm font-medium text-gray-700 dark:text-gray-300">Time</span>
            <input
              className="mt-1 block w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-blue-500 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
              onChange={(event) => setTimeText(event.target.value)}
              placeholder="2h, tomorrow 9am, 14:30"
              ref={timeRef}
              type="text"
              value={timeText}
            />
          </label>
          <label className="block">
            <span className="text-sm font-medium text-gray-700 dark:text-gray-300">Message</span>
            <textarea
              className="mt-1 block min-h-28 w-full resize-y rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-blue-500 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
              onChange={(event) => setBody(event.target.value)}
              value={body}
            />
          </label>
          {error ? <p className="text-sm text-red-700 dark:text-red-300">{error}</p> : null}
          <div className="flex justify-end gap-2">
            <button className={secondaryButton()} disabled={submitting} onClick={onCancel} type="button">Cancel</button>
            <button className={primaryButton()} disabled={submitting} type="submit">Schedule</button>
          </div>
        </form>
      </section>
    </div>
  )
}
