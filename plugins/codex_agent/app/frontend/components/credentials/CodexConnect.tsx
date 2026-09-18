import { useEffect, useRef, useState, type ReactNode } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { createConsumer } from "@rails/actioncable"
import {
  exchangeCodexOauth,
  savePartialCredentials,
  startCodexOauth,
  testCredential,
  type CredentialTestResult
} from "@app/api/credentials"
import { openInNewTab } from "@app/lib/desktopShell"
import { errorMessage } from "@app/lib/errorMessage"
import { inputClass } from "@app/lib/formClasses"
import { useT } from "@app/hooks/useT"
import { Button } from "@app/components/Button"
import { Input } from "@app/components/Input"
import { Select } from "@app/components/Select"
import { StatusBox, Spinner } from "@app/components/credentials/ConnectFlowUi"

type Mode = "api_key" | "chatgpt_login"

// The Codex connect flow, extracted from the Settings page's
// CodexCredentialCard/CodexApiKeySection/CodexChatGptSection so onboarding
// and Settings share the identical experience (the Claude/ClaudeConnect
// convention). Unlike Claude there is no ambient CLI preflight -- Codex
// offers a choice of two independent auth modes up front, and completing
// either one calls onConnected with the already-validated test result.
//
// The onConnected/secondaryAction/autoFocus shape matches
// AgentProviderConnectPanelProps, but onConnected is declared with the
// concrete CredentialTestResult this component always produces (mirroring
// ClaudeConnect) rather than importing that generic, narrower-message type.
export function CodexConnect({
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
  const [mode, setMode] = useState<Mode>("api_key")
  const modeRef = useRef<HTMLSelectElement>(null)

  useEffect(() => {
    if (autoFocus) modeRef.current?.focus()
  }, [autoFocus])

  async function finishConnecting() {
    await queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
    await queryClient.invalidateQueries({ queryKey: ["credentials"] })
  }

  return (
    <div className="space-y-4">
      <label className="block text-[length:var(--text-body)] font-medium text-text-primary">
        {t('credential_cards.codex_auth_mode')}
        <Select className="mt-2" onChange={(event) => setMode(event.target.value as Mode)} ref={modeRef} value={mode}>
          <option value="api_key">{t('account_settings.codex_api_key')}</option>
          <option value="chatgpt_login">{t('account_settings.codex_chatgpt_login')}</option>
        </Select>
      </label>

      {mode === "api_key" ? (
        <CodexApiKeyConnect onConnected={onConnected} onFinishConnecting={finishConnecting} secondaryAction={secondaryAction} />
      ) : (
        <CodexChatGptConnect onConnected={onConnected} onFinishConnecting={finishConnecting} secondaryAction={secondaryAction} />
      )}
    </div>
  )
}

function CodexApiKeyConnect({
  onConnected,
  onFinishConnecting,
  secondaryAction
}: {
  onConnected: (result: CredentialTestResult) => void
  onFinishConnecting: () => Promise<void>
  secondaryAction?: ReactNode
}) {
  const { t } = useT("settings")
  const [apiKey, setApiKey] = useState("")
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function connect(explicitKey?: string) {
    const candidate = (explicitKey ?? apiKey).trim()
    if (candidate.length === 0 || saving) return
    setError(null)
    setSaving(true)
    try {
      await savePartialCredentials({ codex_api_key: candidate, codex_auth_mode: "api_key" })
      const payload = await testCredential("codex_api_key")
      if (payload.credential_test.ok) {
        await onFinishConnecting()
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
    <div className="space-y-3">
      <Input
        aria-label={t('credential_cards.codex_api_key_label')}
        autoComplete="off"
        disabled={saving}
        onChange={(event) => setApiKey(event.target.value)}
        placeholder="sk-…"
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

function CodexChatGptConnect({
  onConnected,
  onFinishConnecting,
  secondaryAction
}: {
  onConnected: (result: CredentialTestResult) => void
  onFinishConnecting: () => Promise<void>
  secondaryAction?: ReactNode
}) {
  const { t } = useT("settings")
  const [authStarted, setAuthStarted] = useState(false)
  const [popupBlocked, setPopupBlocked] = useState<string | null>(null)
  const [authCode, setAuthCode] = useState("")
  const [exchanging, setExchanging] = useState(false)
  const [manualJson, setManualJson] = useState("")
  const [savingManual, setSavingManual] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function authorize() {
    setError(null)
    try {
      const started = await startCodexOauth()
      setPopupBlocked(openInNewTab(started.authorize_url) ? null : started.authorize_url)
      setAuthStarted(true)
    } catch (err) {
      setError(errorMessage(err, t('credential_cards.save_error')))
    }
  }

  async function exchange(codeOverride?: string) {
    const code = (codeOverride ?? authCode).trim()
    if (code.length === 0 || exchanging) return
    setError(null)
    setExchanging(true)
    try {
      const payload = await exchangeCodexOauth(code)
      if (payload.credential_test.ok) {
        await onFinishConnecting()
        setAuthCode("")
        onConnected(payload.credential_test)
      } else {
        setError(payload.credential_test.message || t('credential_cards.test_error'))
      }
    } catch (err) {
      setError(errorMessage(err, t('credential_cards.save_error')))
    } finally {
      setExchanging(false)
    }
  }

  // The desktop/browser callback listener broadcasts the OAuth code over the
  // user's app-event channel; auto-exchange it so the operator never has to
  // paste. Ref-routed so the subscription (created once per auth start)
  // always calls the latest exchange closure.
  const exchangeRef = useRef(exchange)
  exchangeRef.current = exchange

  useEffect(() => {
    if (!authStarted) return

    const consumer = createConsumer()
    const subscription = consumer.subscriptions.create(
      { channel: "AppUserChannel" },
      {
        received(data: unknown) {
          const event = data as { type?: string; payload?: { code?: string } }
          const code = event.type === "codex_oauth.callback" ? event.payload?.code?.trim() : ""
          if (code) {
            setAuthCode(code)
            void exchangeRef.current(code)
          }
        }
      }
    )

    return () => subscription.unsubscribe()
  }, [authStarted])

  async function saveManual() {
    const value = manualJson.trim()
    if (value.length === 0 || savingManual) return
    setError(null)
    setSavingManual(true)
    try {
      await savePartialCredentials({ codex_auth_json: value, codex_auth_mode: "chatgpt_login" })
      const payload = await testCredential("codex_auth_json")
      if (payload.credential_test.ok) {
        await onFinishConnecting()
        setManualJson("")
        onConnected(payload.credential_test)
      } else {
        setError(payload.credential_test.message || t('credential_cards.test_error'))
      }
    } catch (err) {
      setError(errorMessage(err, t('credential_cards.save_error')))
    } finally {
      setSavingManual(false)
    }
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Button onClick={authorize} variant="primary">
          {t('credential_cards.codex_authorize')}
        </Button>
      </div>
      {popupBlocked ? (
        <p className="text-[length:var(--text-caption)] text-warning">
          {t('account_settings.codex_popup_blocked')}{" "}
          <a className="font-medium underline" href={popupBlocked} rel="noreferrer" target="_blank">
            {t('account_settings.codex_open_auth')}
          </a>
          .
        </p>
      ) : null}
      <div className="grid gap-2 sm:grid-cols-[1fr_auto]">
        <Input
          aria-label={t('credential_cards.codex_code_label')}
          autoComplete="off"
          disabled={!authStarted}
          onChange={(event) => setAuthCode(event.target.value)}
          placeholder={authStarted ? t('credential_cards.codex_code_placeholder') : t('credential_cards.codex_code_placeholder_disabled')}
          type="text"
          value={authCode}
        />
        <Button disabled={!authStarted || exchanging || authCode.trim().length === 0} onClick={() => exchange()} variant="secondary">
          {exchanging ? t('account_settings.connecting') : t('credential_cards.connect')}
        </Button>
      </div>
      {error ? <StatusBox tone="error">{error}</StatusBox> : null}

      <details className="rounded-[var(--radius-panel)] border border-border p-3">
        <summary className="cursor-pointer text-[length:var(--text-body)] text-text-primary">{t('account_settings.paste_auth_json')}</summary>
        <div className="mt-3 space-y-2">
          <textarea
            aria-label={t('credential_cards.codex_auth_json_label')}
            className={`${inputClass()} font-mono text-xs`}
            onChange={(event) => setManualJson(event.target.value)}
            rows={6}
            value={manualJson}
          />
          <div className="flex items-center justify-between gap-2">
            <p className="text-[length:var(--text-caption)] text-text-secondary">{t('account_settings.auth_json_help')}</p>
            <Button disabled={manualJson.trim().length === 0 || savingManual} onClick={saveManual} size="sm" variant="secondary">
              {savingManual ? t('credential_cards.saving') : t('credential_cards.save')}
            </Button>
          </div>
        </div>
      </details>

      <div className="flex items-center justify-end gap-2">{secondaryAction}</div>
    </div>
  )
}
