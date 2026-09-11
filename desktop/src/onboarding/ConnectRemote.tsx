import { useEffect, useMemo, useRef, useState, type FormEvent } from "react"
import { analyzeInstanceUrl } from "./instanceUrl"
import { FooterRow, FormError, OnboardingScreen, Spinner, ValidationHint } from "./primitives"
import { t } from "../i18n"

type ConnectRemoteProps = {
  error: string | null
  busy: boolean
  checkingUrl?: string
  onSubmit: (url: string) => void
  onBack: () => void
}

const PROBE_DEBOUNCE_MS = 600

type ProbeState =
  | { status: "idle" }
  | { status: "checking"; url: string }
  | { status: "ok"; url: string }
  | { status: "fail"; message: string }

// Connect takes only the instance URL. There is deliberately no API-token
// field here: signing in inside the app window mints the tray token
// automatically (tokenProvisioner), and the manual-token path for non-admin
// accounts lives in Preferences.
//
// The live feedback is honest: the green check only appears when a Syrus
// actually answered at the previewed address (debounced main-process probe),
// never because the string merely parses. Submitting doesn't wait for the
// probe — connectRemote re-checks authoritatively.
export function ConnectRemote({ error, busy, checkingUrl, onSubmit, onBack }: ConnectRemoteProps) {
  const [url, setUrl] = useState(checkingUrl ?? "")
  const [probe, setProbe] = useState<ProbeState>({ status: "idle" })
  const probeSeq = useRef(0)
  const analysis = useMemo(() => analyzeInstanceUrl(url), [url])

  useEffect(() => {
    // Every keystroke invalidates any in-flight probe result.
    probeSeq.current += 1
    const seq = probeSeq.current

    if (analysis.state === "empty" || analysis.state === "invalid" || analysis.normalized === null) {
      setProbe({ status: "idle" })
      return
    }

    const target = analysis.normalized
    setProbe({ status: "checking", url: target })
    const timer = window.setTimeout(() => {
      window.syrusDesktop
        .probeInstance({ url })
        .then((result) => {
          if (probeSeq.current !== seq) {
            return
          }
          setProbe(result.ok ? { status: "ok", url: result.url ?? target } : { status: "fail", message: result.message })
        })
        .catch(() => {
          if (probeSeq.current === seq) {
            setProbe({ status: "fail", message: t("onboarding.connect.check_failed") })
          }
        })
    }, PROBE_DEBOUNCE_MS)

    return () => window.clearTimeout(timer)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [url])

  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (!busy) {
      onSubmit(url.trim())
    }
  }

  const hintState =
    analysis.state === "invalid"
      ? "invalid"
      : analysis.state === "empty"
        ? "empty"
        : probe.status === "ok"
          ? "valid"
          : probe.status === "fail"
            ? "invalid"
            : "note"

  const hintText =
    analysis.state === "invalid" ? (
      analysis.hint
    ) : analysis.state === "empty" ? (
      ""
    ) : probe.status === "ok" ? (
      t("onboarding.connect.found", { url: probe.url })
    ) : probe.status === "fail" ? (
      probe.message
    ) : (
      <span className="inline-flex items-center gap-1.5">
        <Spinner />
        {t("onboarding.connect.checking", { url: analysis.normalized })}
      </span>
    )

  return (
    <OnboardingScreen
      title={t("onboarding.connect.title")}
      subtitle={t("onboarding.connect.subtitle")}
    >
      <form className="mt-6 space-y-4" onSubmit={handleSubmit}>
        <label className="block">
          <span>{t("onboarding.connect.instance_address")}</span>
          <input
            type="text"
            inputMode="url"
            autoFocus
            required
            value={url}
            disabled={busy}
            placeholder={t("onboarding.connect.placeholder")}
            onChange={(event) => setUrl(event.target.value)}
            spellCheck={false}
            autoCapitalize="off"
            autoCorrect="off"
          />
          <ValidationHint state={hintState}>{hintText}</ValidationHint>
        </label>

        <FormError>{error}</FormError>

        <FooterRow>
          {/* Back stays enabled while checking so a black-holed host is never a dead end. */}
          <button type="button" className="secondary-button" onClick={onBack}>
            {t("common.back")}
          </button>
          <button
            type="submit"
            className="primary-button inline-flex items-center gap-2"
            disabled={busy || analysis.state === "invalid" || analysis.state === "empty"}
          >
            {busy ? (
              <>
                <Spinner />
                {t("common.connecting")}
              </>
            ) : (
              t("common.connect")
            )}
          </button>
        </FooterRow>
      </form>
    </OnboardingScreen>
  )
}
