import syrusIconUrl from "../assets/syrusIcon.png"
import { t } from "./i18n"

// Shown in the web-container window when the Syrus backend isn't answering.
// This surface is deliberately inert: the window has no preload bridge (the
// remote web app must never see it), so the main process polls the backend
// and swaps this page back out the moment it responds.
const DETAIL_MESSAGES: Record<string, { title: string; body: string }> = {
  remote: {
    title: t("backend.remote.title"),
    body: t("backend.remote.body")
  },
  "daemon-down": {
    title: t("backend.daemon_down.title"),
    body: t("backend.daemon_down.body")
  },
  "containers-down": {
    title: t("backend.containers_down.title"),
    body: t("backend.containers_down.body")
  },
  stopped: {
    title: t("backend.stopped.title"),
    body: t("backend.stopped.body")
  },
  "data-gone": {
    title: t("backend.data_gone.title"),
    body: t("backend.data_gone.body")
  }
}

const DEFAULT_MESSAGE = {
  title: t("backend.default.title"),
  body: t("backend.default.body")
}

export function BackendStatus() {
  const params = new URLSearchParams(window.location.search)
  const detail = params.get("detail")
  const message = (detail && DETAIL_MESSAGES[detail]) || DEFAULT_MESSAGE

  return (
    <div className="flex h-screen flex-col items-center justify-center bg-slate-50 px-10 text-center text-slate-900 antialiased dark:bg-slate-950 dark:text-slate-100">
      <img src={syrusIconUrl} alt="" className="h-12 w-12 opacity-70" />
      <h1 className="mt-5 text-xl font-semibold">{message.title}</h1>
      <p className="mt-2 max-w-sm text-sm leading-relaxed text-slate-600 dark:text-slate-400">{message.body}</p>
      <p className="mt-3 max-w-sm text-xs leading-relaxed text-slate-400 dark:text-slate-500">
        {t("backend.reset_hint")}
      </p>
      <p className="mt-6 text-sm text-slate-400 dark:text-slate-500" role="status">
        <span
          aria-hidden
          className="mr-2 inline-block h-3 w-3 animate-spin rounded-full border-2 border-slate-400 border-t-transparent align-middle dark:border-slate-600"
        />
        {t("backend.checking")}
      </p>
    </div>
  )
}
