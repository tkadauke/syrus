import { useId, useMemo } from "react"
import "@excalidraw/excalidraw/index.css"
import { useT } from "../../hooks/useT"
import { providerLabel } from "./utils"




// Chat message-stream chrome extracted from Chat.tsx: the timestamp, day
// divider, decorative wave line, system-messages toggle, and the agent-
// activity / switching-provider indicators rendered around the message list.

export function MessageTimestamp({ time, fullDatetime }: { time: string; fullDatetime: string }) {
  return (
    <div className="flex justify-center py-1" title={fullDatetime}>
      <span className="text-xs text-gray-400 dark:text-gray-500">{time}</span>
    </div>
  )
}

export function DayDivider({ date: _date, label }: { date: string; label: string }) {
  const id = useId()

  return (
    <div className="flex items-center gap-3 py-3">
      <WaveLine patternId={`wave-${id}-left`} />
      <span className="whitespace-nowrap text-xs text-gray-300 dark:text-gray-700">{label}</span>
      <WaveLine patternId={`wave-${id}-right`} />
    </div>
  )
}

function WaveLine({ patternId }: { patternId: string }) {
  return (
    <svg className="h-[8px] flex-1 text-gray-300 dark:text-gray-700" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <pattern height="8" id={patternId} patternUnits="userSpaceOnUse" width="20" x="0" y="0">
          <path d="M0,4 C5,0 10,8 15,4 C20,0 25,8 30,4" fill="none" stroke="currentColor" strokeWidth="1.5" />
        </pattern>
      </defs>
      <rect fill={`url(#${patternId})`} height="100%" width="100%" />
    </svg>
  )
}

export function SystemMessagesToggle({ count, expanded, onToggle }: { count: number; expanded: boolean; onToggle: () => void }) {
  const { t } = useT("chat")
  return (
    <div className="flex justify-center">
      <button className="rounded-full border border-gray-200 bg-white px-3 py-1 text-xs font-medium text-gray-600 shadow-sm hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300 dark:hover:bg-gray-800" onClick={onToggle} type="button">
        {expanded ? t("hide_system_messages") : t("show_system_messages", { count })}
      </button>
    </div>
  )
}

const WORKING_PHRASES = [
  { latin: "Cogitans", english: "thinking it through" },
  { latin: "Machinans", english: "contriving, plotting" },
  { latin: "Moliens", english: "striving, setting in motion" },
  { latin: "Meditans", english: "planning, turning over in the mind" },
  { latin: "Excogitans", english: "thinking out, devising" },
  { latin: "Elaborans", english: "working it out carefully" },
  { latin: "Perscrutans", english: "examining thoroughly" },
  { latin: "Computans", english: "calculating" },
  { latin: "Conficiens", english: "bringing to completion" },
  { latin: "Agitans", english: "setting things in motion" },
  { latin: "Evolvens", english: "unrolling, unfolding" },
  { latin: "Ponderans", english: "weighing carefully" },
  { latin: "Consilians", english: "taking counsel, deliberating" },
  { latin: "Exsequens", english: "carrying out, executing" },
  { latin: "Investigans", english: "tracking down, hunting through" },
  { latin: "Versans", english: "turning over in the mind" },
  { latin: "Struens", english: "building, constructing" },
  { latin: "Nectens", english: "weaving together, binding" },
  { latin: "Vigilans", english: "keeping watch" },
  { latin: "Expediens", english: "making ready, dispatching" }
] as const

export function getStartingPhrase() {
  const now = new Date()
  if (now.getMonth() === 2 && now.getDate() === 15) {
    return { latin: "Cave, Idus Martias.", english: "Beware the Ides of March." }
  }
  return { latin: "Accingitur", english: "girding itself" }
}

export function AgentActivityIndicator({ running }: { running: boolean }) {
  const workingPhrase = useMemo(
    () => WORKING_PHRASES[Math.floor(Math.random() * WORKING_PHRASES.length)],
    []
  )
  const phrase = running ? workingPhrase : getStartingPhrase()

  return (
    <div aria-label={phrase.english} aria-live="polite" className="flex justify-start" role="status">
      <div className="inline-flex items-center gap-2 rounded-full border border-info/20 bg-info/10 px-3 py-1.5 text-xs font-medium text-info shadow-sm dark:border-info/30 dark:bg-info/10 dark:text-info">
        <span aria-hidden="true" className="inline-flex items-center gap-1">
          {[0, 1, 2].map((index) => (
            <span
              className="h-1.5 w-1.5 animate-bounce rounded-full bg-info"
              key={index}
              style={{ animationDelay: `${index * 140}ms` }}
            />
          ))}
        </span>
        <span title={phrase.english}>{phrase.latin}</span>
      </div>
    </div>
  )
}

export function SwitchingProviderIndicator({ provider }: { provider: string }) {
  const { t } = useT("chat")
  const label = t("switching_to_provider", { provider: providerLabel(provider) })
  return (
    <div aria-label={label} aria-live="polite" className="flex justify-start" role="status">
      <div className="inline-flex items-center gap-2 rounded-full border border-amber-100 bg-amber-50 px-3 py-1.5 text-xs font-medium text-amber-700 shadow-sm dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200">
        <span aria-hidden="true" className="inline-flex items-center gap-1">
          {[0, 1, 2].map((index) => (
            <span
              className="h-1.5 w-1.5 animate-bounce rounded-full bg-amber-500 dark:bg-amber-300"
              key={index}
              style={{ animationDelay: `${index * 140}ms` }}
            />
          ))}
        </span>
        <span>{label}</span>
      </div>
    </div>
  )
}
