import syrusIconUrl from "../assets/syrusIcon.png"

// Shown in the web-container window when the Syrus backend isn't answering.
// This surface is deliberately inert: the window has no preload bridge (the
// remote web app must never see it), so the main process polls the backend
// and swaps this page back out the moment it responds.
const DETAIL_MESSAGES: Record<string, { title: string; body: string }> = {
  remote: {
    title: "Waiting for Syrus…",
    body: "Your Syrus instance isn't reachable right now. This window reconnects automatically."
  },
  "daemon-down": {
    title: "Docker isn't running",
    body: "Your Docker runtime (OrbStack or Docker Desktop) has stopped. Open it — or choose Backend → Start Syrus — and this window reconnects automatically."
  },
  "containers-down": {
    title: "Syrus has stopped",
    body: "The Syrus containers aren't running. Choose Backend → Start Syrus; this window reconnects automatically."
  },
  stopped: {
    title: "Syrus is stopped",
    body: "You stopped Syrus, so GitHub polling and agent runs are paused. Start it again from Backend → Start Syrus."
  },
  "data-gone": {
    title: "Your Syrus data is gone",
    body: "Docker is running, but the Syrus data volume no longer exists — it may have been deleted along with your containers. Syrus needs a fresh setup."
  }
}

const DEFAULT_MESSAGE = {
  title: "Waiting for Syrus…",
  body: "Syrus isn't answering yet — it may still be starting. This window reconnects automatically. You can also start or restart it from the Backend menu."
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
        Removed or moved your Syrus? Choose <span className="font-medium">Syrus → Run Setup Again…</span>{" "}
        from the menu to start over.
      </p>
      <p className="mt-6 text-sm text-slate-400 dark:text-slate-500" role="status">
        <span
          aria-hidden
          className="mr-2 inline-block h-3 w-3 animate-spin rounded-full border-2 border-slate-400 border-t-transparent align-middle dark:border-slate-600"
        />
        Checking again…
      </p>
    </div>
  )
}
