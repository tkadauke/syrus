import { useEffect, useRef, useState, type ReactNode } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { savePartialCredentials, testCredential, testGeminiKey, type CredentialTestResult } from "@app/api/credentials"
import { openInNewTab } from "@app/lib/desktopShell"
import { errorMessage } from "@app/lib/errorMessage"
import { useT } from "@app/hooks/useT"
import { Button } from "@app/components/Button"
import { Input } from "@app/components/Input"
import { StatusBox } from "@app/components/credentials/ConnectFlowUi"
import { ValidationStages, type StageStatus, type ValidationStage as GenericValidationStage } from "@app/components/credentials/ValidationStages"
import { looksLikeGeminiKey } from "@app/components/GeminiSetupSheet"

type ValidationStage = GenericValidationStage<"format" | "reach">

const INITIAL_STAGES: ValidationStage[] = [
  { key: "format", status: "pending" },
  { key: "reach", status: "pending" }
]

// Antigravity has no secret of its own -- connecting it means saving the
// shared Gemini API key, so this reuses the same format-then-reach
// validation cascade GeminiSetupSheet uses (extracted as ValidationStages /
// looksLikeGeminiKey) rendered inline (no Modal wrapper) to conform to the
// generic connect-panel shape. The final confirmation goes through the
// "agy" credential probe rather than the raw Gemini probe response, so the
// message reads as Antigravity (not just Gemini) being ready.
//
// The onConnected/secondaryAction/autoFocus shape matches
// AgentProviderConnectPanelProps, but onConnected is declared with the
// concrete CredentialTestResult this component always produces (mirroring
// ClaudeConnect) rather than importing that generic, narrower-message type.
export function AgyConnect({
  autoFocus = false,
  onConnected,
  secondaryAction
}: {
  autoFocus?: boolean
  onConnected: (result: CredentialTestResult) => void
  secondaryAction?: ReactNode
}) {
  const { t } = useT(["settings", "chat"])
  const queryClient = useQueryClient()
  const [key, setKey] = useState("")
  const [stages, setStages] = useState<ValidationStage[]>(INITIAL_STAGES)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (autoFocus) inputRef.current?.focus()
  }, [autoFocus])

  function setStage(stageKey: ValidationStage["key"], status: StageStatus) {
    setStages((current) => current.map((stage) => (stage.key === stageKey ? { ...stage, status } : stage)))
  }

  async function connect(explicitKey?: string) {
    if (busy) return
    const candidate = (explicitKey ?? key).trim()
    setError(null)
    setStages(INITIAL_STAGES.map((stage) => ({ ...stage })))
    setBusy(true)

    try {
      setStage("format", "running")
      if (!looksLikeGeminiKey(candidate)) {
        setStage("format", "failed")
        setError(t("chat:gemini_setup_key_help"))
        return
      }
      setStage("format", "ok")

      setStage("reach", "running")
      const probe = await testGeminiKey(candidate)
      if (!probe.credential_test.ok) {
        setStage("reach", "failed")
        setError(probe.credential_test.message || t("credential_cards.test_error"))
        return
      }
      setStage("reach", "ok")

      await savePartialCredentials({ gemini_api_key: candidate })
      const agyTest = await testCredential("agy")
      await queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
      await queryClient.invalidateQueries({ queryKey: ["credentials"] })
      setKey("")
      onConnected(agyTest.credential_test)
    } catch (err) {
      setStage("reach", "failed")
      setError(errorMessage(err, t("credential_cards.save_error")))
    } finally {
      setBusy(false)
    }
  }

  const stageLabels: Record<ValidationStage["key"], string> = {
    format: t("chat:gemini_stage_format"),
    reach: t("chat:gemini_stage_reach")
  }

  return (
    <div className="space-y-4">
      <p className="text-[length:var(--text-body)] text-text-secondary">{t("credential_cards.agy_description")}</p>
      <button
        className="text-sm font-medium text-brand-emphasis underline hover:text-brand dark:text-brand-emphasis"
        onClick={() => openInNewTab("https://aistudio.google.com/apikey")}
        type="button"
      >
        {t("chat:gemini_setup_get_key")}
      </button>
      <Input
        aria-label={t("chat:gemini_setup_placeholder")}
        autoComplete="off"
        className="font-mono"
        disabled={busy}
        onChange={(event) => setKey(event.target.value)}
        onPaste={(event) => {
          const pasted = event.clipboardData.getData("text").trim()
          if (pasted.length === 0 || busy) return
          event.preventDefault()
          setKey(pasted)
          setTimeout(() => void connect(pasted), 0)
        }}
        placeholder={t("chat:gemini_setup_placeholder")}
        ref={inputRef}
        spellCheck={false}
        type="password"
        value={key}
      />

      <ValidationStages labels={stageLabels} stages={stages} testIdPrefix="agy" />

      {error ? <StatusBox tone="error">{error}</StatusBox> : null}

      <div className="flex items-center justify-end gap-2">
        {secondaryAction}
        <Button disabled={busy || key.trim().length === 0} onClick={() => connect()} variant="primary">
          {busy ? t("chat:gemini_setup_validating") : t("chat:gemini_setup_save")}
        </Button>
      </div>
    </div>
  )
}
