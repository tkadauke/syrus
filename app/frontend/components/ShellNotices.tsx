import { useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { syrusShellBridge, type SyrusShellBridge, type SyrusShellState } from "../lib/desktopShell"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { CloseIcon } from "./CloseIcon"

// How long the "Skill installed ✓" confirmation lingers before the notice
// removes itself.
export const SKILL_INSTALLED_CONFIRMATION_MS = 2500

// Quiet notice stack pinned at the bottom of the sidebar, directly above the
// account row. Fed by the desktop shell's window.syrusShell preload bridge;
// plain browsers (and older shells) have no bridge, so this renders nothing.
export function ShellNotices() {
  const bridge = syrusShellBridge()
  if (!bridge) return null

  return <BridgedShellNotices bridge={bridge} />
}

type SkillPhase = "idle" | "installing" | "installed" | "done"

function BridgedShellNotices({ bridge }: { bridge: SyrusShellBridge }) {
  const [state, setState] = useState<SyrusShellState | null>(null)

  useEffect(() => {
    let cancelled = false
    let sawEvent = false
    void bridge
      .getState()
      .then((next) => {
        // A state-changed event that lands before this snapshot resolves is
        // fresher than the snapshot — never clobber it with stale data.
        if (!cancelled && !sawEvent) setState(next)
      })
      .catch(() => {
        // A misbehaving bridge (e.g. shell mid-update) simply shows no notices.
      })
    const unsubscribe = bridge.onStateChanged((next) => {
      sawEvent = true
      setState(next)
    })
    return () => {
      cancelled = true
      unsubscribe()
    }
  }, [bridge])

  if (!state) return null

  const update = state.updateReadyVersion ? <UpdateNotice bridge={bridge} version={state.updateReadyVersion} /> : null
  const skill = <SkillOfferNotice bridge={bridge} state={state} />

  return (
    <div className="shrink-0 space-y-2 px-3 pb-2 empty:hidden" data-testid="shell-notices">
      {update}
      {skill}
    </div>
  )
}

function UpdateNotice({ bridge, version }: { bridge: SyrusShellBridge; version: string }) {
  const { t } = useTranslation("nav")

  return (
    <button
      className={`${noticeBoxClass()} block w-full text-left hover:border-gray-300 hover:bg-gray-100 dark:hover:border-gray-600 dark:hover:bg-gray-800`}
      onClick={() => bridge.relaunchToUpdate()}
      type="button"
    >
      <span className="block font-medium text-gray-700 dark:text-gray-200">{t("shell.update_ready")}</span>
      <span className="mt-0.5 block text-[11px] text-gray-500 dark:text-gray-400">{t("shell.update_version", { version })}</span>
    </button>
  )
}

function SkillOfferNotice({ bridge, state }: { bridge: SyrusShellBridge; state: SyrusShellState }) {
  const { t } = useTranslation("nav")
  const [phase, setPhase] = useState<SkillPhase>("idle")
  const [error, setError] = useState<string | null>(null)
  const [dismissed, setDismissed] = useState(false)
  const [infoOpen, setInfoOpen] = useState(false)
  const infoRef = useDismissiblePopup<HTMLSpanElement>(infoOpen, () => setInfoOpen(false))
  const confirmationTimer = useRef<number | null>(null)

  useEffect(() => {
    return () => {
      if (confirmationTimer.current != null) window.clearTimeout(confirmationTimer.current)
    }
  }, [])

  // The brief "installed ✓" confirmation outlives the shell flipping
  // skillInstalled to true; everything else follows the bridge state.
  const offered = state.claudeDetected && !state.skillInstalled && !state.skillOfferDismissed && !dismissed
  if (phase === "done" || (!offered && phase !== "installed")) return null

  function install() {
    setPhase("installing")
    setError(null)
    void bridge
      .installSkill()
      .then((result) => {
        if (result.ok) {
          setPhase("installed")
          confirmationTimer.current = window.setTimeout(() => setPhase("done"), SKILL_INSTALLED_CONFIRMATION_MS)
        } else {
          setPhase("idle")
          setError(result.message)
        }
      })
      .catch(() => {
        setPhase("idle")
        setError(t("shell.skill_install_failed"))
      })
  }

  function dismiss() {
    bridge.dismissSkillOffer()
    setDismissed(true)
  }

  if (phase === "installed") {
    return (
      <div className={noticeBoxClass()} role="status">
        <span className="font-medium text-emerald-700 dark:text-emerald-300">{t("shell.skill_installed")}</span>
      </div>
    )
  }

  return (
    <div className={noticeBoxClass()}>
      <div className="flex items-start gap-1.5">
        <span className="min-w-0 flex-1 font-medium text-gray-700 dark:text-gray-200">{t("shell.skill_offer")}</span>
        <span className="relative" ref={infoRef}>
          <button
            aria-expanded={infoOpen}
            aria-label={t("shell.skill_info_label")}
            className="inline-flex h-5 w-5 items-center justify-center rounded text-gray-400 hover:bg-gray-200 hover:text-gray-600 dark:text-gray-500 dark:hover:bg-gray-700 dark:hover:text-gray-300"
            onClick={() => setInfoOpen((open) => !open)}
            title={t("shell.skill_info")}
            type="button"
          >
            <InfoIcon />
          </button>
          {infoOpen ? (
            <span className="absolute bottom-full right-0 z-30 mb-1 block w-56 rounded border border-gray-200 bg-white p-2 text-[11px] font-normal text-gray-600 shadow-lg dark:border-gray-700 dark:bg-gray-950 dark:text-gray-300" role="note">
              {t("shell.skill_info")}
            </span>
          ) : null}
        </span>
        <button
          aria-label={t("shell.skill_dismiss")}
          className="inline-flex h-5 w-5 items-center justify-center rounded text-gray-400 hover:bg-gray-200 hover:text-gray-600 dark:text-gray-500 dark:hover:bg-gray-700 dark:hover:text-gray-300"
          onClick={dismiss}
          type="button"
        >
          <CloseIcon className="h-3.5 w-3.5" />
        </button>
      </div>
      {error ? <p className="mt-1 text-[11px] text-red-600 dark:text-red-400">{error}</p> : null}
      <div className="mt-1.5">
        <button
          className="rounded border border-gray-300 bg-white px-2 py-1 text-[11px] font-medium text-gray-700 hover:bg-gray-100 disabled:cursor-not-allowed disabled:opacity-60 dark:border-gray-600 dark:bg-gray-950 dark:text-gray-200 dark:hover:bg-gray-800"
          disabled={phase === "installing"}
          onClick={install}
          type="button"
        >
          {phase === "installing" ? t("shell.skill_installing") : t("shell.skill_install")}
        </button>
      </div>
    </div>
  )
}

function noticeBoxClass() {
  return "rounded-md border border-gray-200 bg-gray-50 px-2.5 py-2 text-xs dark:border-gray-700 dark:bg-gray-900"
}

function InfoIcon() {
  return (
    <svg aria-hidden="true" className="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24">
      <path d="M12 11v5.25M12 7.9v.02M12 20.25a8.25 8.25 0 1 0 0-16.5 8.25 8.25 0 0 0 0 16.5Z" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
    </svg>
  )
}
