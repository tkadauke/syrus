import { useEffect, useRef, useState, type ReactNode } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { savePartialCredentials, testCredential, type CredentialTestResult } from "@app/api/credentials"
import { errorMessage } from "@app/lib/errorMessage"
import { useT } from "@app/hooks/useT"
import { Button } from "@app/components/Button"
import { Input } from "@app/components/Input"
import { StatusBox, Spinner } from "@app/components/credentials/ConnectFlowUi"

// The Muse connect flow: a single API key, paste-to-connect (mirroring the
// Claude/Gemini paste conventions), saved then validated in one step so
// onConnected only fires once the key is confirmed working. Extracted from
// the Settings page's MuseCredentialCard.
//
// The onConnected/secondaryAction/autoFocus shape matches
// AgentProviderConnectPanelProps, but onConnected is declared with the
// concrete CredentialTestResult this component always produces (mirroring
// ClaudeConnect) rather than importing that generic, narrower-message type.
export function MuseConnect({
  autoFocus = false,
  onConnected,
  secondaryAction
}: {
  autoFocus?: boolean
  onConnected: (result: CredentialTestResult) => void
  secondaryAction?: ReactNode
}) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [apiKey, setApiKey] = useState("")
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (autoFocus) inputRef.current?.focus()
  }, [autoFocus])

  async function connect(explicitKey?: string) {
    const candidate = (explicitKey ?? apiKey).trim()
    if (candidate.length === 0 || saving) return
    setError(null)
    setSaving(true)
    try {
      await savePartialCredentials({ muse_api_key: candidate })
      const payload = await testCredential("muse_api_key")
      if (payload.credential_test.ok) {
        await queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
        await queryClient.invalidateQueries({ queryKey: ["credentials"] })
        setApiKey("")
        onConnected(payload.credential_test)
      } else {
        setError(payload.credential_test.message || t('credential_cards.test_error'))
      }
    } catch (err) {
      setError(errorMessage(err, t('credential_cards.save_error')))
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="space-y-4">
      <p className="text-[length:var(--text-body)] text-text-secondary">
        {t('credential_cards.muse_description')}{" "}
        <a
          className="font-medium text-brand-emphasis underline hover:text-brand dark:text-brand-emphasis"
          href="https://ai.developer.meta.com/"
          rel="noreferrer"
          target="_blank"
        >
          ai.developer.meta.com
        </a>{" "}
        {t('credential_cards.muse_description_suffix')}
      </p>
      <Input
        aria-label={t('credential_cards.muse_api_key_label')}
        autoComplete="off"
        disabled={saving}
        onChange={(event) => setApiKey(event.target.value)}
        onPaste={(event) => {
          const pasted = event.clipboardData.getData("text").trim()
          if (pasted.length === 0 || saving) return
          event.preventDefault()
          setApiKey(pasted)
          setTimeout(() => void connect(pasted), 0)
        }}
        placeholder="LLM|…"
        ref={inputRef}
        spellCheck={false}
        type="password"
        value={apiKey}
      />
      {error ? <StatusBox tone="error">{error}</StatusBox> : null}
      <div className="flex items-center justify-end gap-2">
        {secondaryAction}
        <Button disabled={apiKey.trim().length === 0 || saving} onClick={() => connect()} variant="primary">
          {saving ? (
            <>
              <Spinner light /> {t('credential_cards.saving')}
            </>
          ) : (
            t('credential_cards.connect')
          )}
        </Button>
      </div>
    </div>
  )
}
