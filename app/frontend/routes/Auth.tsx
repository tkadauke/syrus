import { inputClass } from "../lib/formClasses"
import { routePrefix } from "../lib/routing"
import { useMutation, useQuery } from "@tanstack/react-query"
import type { FormEvent, KeyboardEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import { Trans } from "react-i18next"
import { Link, useLocation, useParams } from "react-router-dom"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { authPrimaryButtonClass } from "../lib/buttonStyles"
import { NoticeToast } from "../components/NoticeToast"
import { CapsLockHint, EmailValidityHint, PasswordMatchHint, PasswordStrengthMeter } from "../components/PasswordFeedback"
import {
  fetchSignup,
  requestPasswordReset,
  resetPassword,
  signIn,
  signUp,
  type SignupPayload
} from "../api/auth"
import { errorMessage } from "../lib/errorMessage"

export function SignInRoute() {
  const { t } = useT("auth")
  usePageTitle(t("sign_in.title"))
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const [emailAddress, setEmailAddress] = useState("")
  const [password, setPassword] = useState("")
  const [capsLock, setCapsLock] = useState(false)
  const submit = useMutation({
    mutationFn: () => signIn({ email_address: emailAddress, password }),
    onSuccess: (payload) => assignWithPrefix(prefix, payload.redirect_to)
  })

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    submit.mutate()
  }

  function trackCapsLock(event: KeyboardEvent<HTMLInputElement>) {
    setCapsLock(event.getModifierState("CapsLock"))
  }

  return (
    <AuthShell
      title={t("sign_in.title")}
      subtitle={t("sign_in.subtitle")}
    >
      <form className="space-y-5" onSubmit={onSubmit}>
        {submit.isError ? <PanelMessage tone="error">{errorMessage(submit.error, t("sign_in.error"))}</PanelMessage> : null}
        <Field label={t("field.email")}>
          <input
            autoComplete="username"
            autoFocus
            className={inputClass()}
            onChange={(event) => setEmailAddress(event.target.value)}
            required
            type="email"
            value={emailAddress}
          />
          <EmailValidityHint email={emailAddress} />
        </Field>
        <Field label={t("field.password")}>
          <input
            autoComplete="current-password"
            className={inputClass()}
            maxLength={72}
            onChange={(event) => setPassword(event.target.value)}
            onKeyDown={trackCapsLock}
            onKeyUp={trackCapsLock}
            required
            type="password"
            value={password}
          />
          <CapsLockHint active={capsLock} />
        </Field>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
          <button className={authPrimaryButtonClass} disabled={submit.isPending} type="submit">
            {submit.isPending ? t("sign_in.submitting") : t("sign_in.submit")}
          </button>
          <Link className="text-sm text-gray-700 dark:text-gray-300 underline hover:no-underline" to={`${prefix}/passwords/new`}>{t("sign_in.forgot")}</Link>
        </div>
      </form>
    </AuthShell>
  )
}

export function SignUpRoute() {
  const { t } = useT("auth")
  usePageTitle(t("sign_up.title"))
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const signup = useQuery({
    queryKey: ["auth", "signup", location.search],
    queryFn: () => fetchSignup(location.search)
  })

  return (
    <AuthShell
      title={t("sign_up.title")}
      subtitle={t("sign_up.subtitle")}
    >
      {signup.isPending ? <PanelMessage>{t("sign_up.loading")}</PanelMessage> : null}
      {signup.isError ? <PanelMessage tone="error">{errorMessage(signup.error, t("sign_up.error_load"))}</PanelMessage> : null}
      {signup.isSuccess ? <SignUpForm payload={signup.data} prefix={prefix} /> : null}
    </AuthShell>
  )
}

function SignUpForm({ payload, prefix }: { payload: SignupPayload; prefix: string }) {
  const { t } = useT("auth")
  const [emailAddress, setEmailAddress] = useState(payload.invitation?.email_address || "")
  const [password, setPassword] = useState("")
  const [passwordConfirmation, setPasswordConfirmation] = useState("")
  const submit = useMutation({
    mutationFn: () => signUp({
      email_address: emailAddress,
      password,
      password_confirmation: passwordConfirmation,
      invitation_token: payload.invitation?.token
    }),
    onSuccess: (saved) => assignWithPrefix(prefix, saved.redirect_to)
  })

  useEffect(() => {
    setEmailAddress(payload.invitation?.email_address || "")
  }, [payload.invitation?.email_address])

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    submit.mutate()
  }

  if (!payload.allowed) {
    return (
      <PanelMessage tone="error">
        <Trans
          t={t}
          i18nKey="sign_up.invite_only"
          components={{ signin: <Link className="underline hover:no-underline" to={`${prefix}/session/new`} /> }}
        />
      </PanelMessage>
    )
  }

  return (
    <form className="space-y-5" onSubmit={onSubmit}>
      {payload.invitation ? <PanelMessage>{t("sign_up.accepting_invite", { email: payload.invitation.invited_by_email })}</PanelMessage> : null}
      {payload.first_signup ? <PanelMessage>{t("sign_up.first_admin")}</PanelMessage> : null}
      {submit.isError ? <PanelMessage tone="error">{errorMessage(submit.error, t("sign_up.error_create"))}</PanelMessage> : null}
      <Field label={t("field.email")}>
        <input
          autoComplete="username"
          autoFocus
          className={inputClass()}
          onChange={(event) => setEmailAddress(event.target.value)}
          required
          type="email"
          value={emailAddress}
        />
        <EmailValidityHint email={emailAddress} />
      </Field>
      <Field label={t("field.password")}>
        <input
          autoComplete="new-password"
          className={inputClass()}
          maxLength={72}
          onChange={(event) => setPassword(event.target.value)}
          required
          type="password"
          value={password}
        />
        <PasswordStrengthMeter password={password} />
      </Field>
      <Field label={t("field.confirm_password")}>
        <input
          autoComplete="new-password"
          className={inputClass()}
          maxLength={72}
          onChange={(event) => setPasswordConfirmation(event.target.value)}
          required
          type="password"
          value={passwordConfirmation}
        />
        <PasswordMatchHint confirmation={passwordConfirmation} password={password} />
      </Field>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
        <button className={authPrimaryButtonClass} disabled={submit.isPending} type="submit">
          {submit.isPending ? t("sign_up.submitting") : t("sign_up.submit")}
        </button>
        {/* No accounts exist yet on the first signup — nobody to sign in as. */}
        {payload.first_signup ? null : <Link className="text-sm text-gray-700 dark:text-gray-300 underline hover:no-underline" to={`${prefix}/session/new`}>{t("sign_up.have_account")}</Link>}
      </div>
    </form>
  )
}

export function PasswordRequestRoute() {
  const { t } = useT("auth")
  usePageTitle(t("password_request.title"))
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const [emailAddress, setEmailAddress] = useState("")
  const [notice, setNotice] = useState<string | null>(null)
  const submit = useMutation({
    mutationFn: () => requestPasswordReset(emailAddress),
    onSuccess: (payload) => setNotice(payload.message)
  })

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setNotice(null)
    submit.mutate()
  }

  return (
    <AuthShell
      title={t("password_request.title")}
      subtitle={t("password_request.subtitle")}
    >
      <form className="space-y-5" onSubmit={onSubmit}>
        <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
        {submit.isError ? <PanelMessage tone="error">{errorMessage(submit.error, t("password_request.error"))}</PanelMessage> : null}
        <Field label={t("field.email")}>
          <input
            autoComplete="username"
            autoFocus
            className={inputClass()}
            onChange={(event) => setEmailAddress(event.target.value)}
            required
            type="email"
            value={emailAddress}
          />
          <EmailValidityHint email={emailAddress} />
        </Field>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
          <button className={authPrimaryButtonClass} disabled={submit.isPending} type="submit">
            {submit.isPending ? t("password_request.submitting") : t("password_request.submit")}
          </button>
          <Link className="text-sm text-gray-700 dark:text-gray-300 underline hover:no-underline" to={`${prefix}/session/new`}>{t("back_to_sign_in")}</Link>
        </div>
      </form>
    </AuthShell>
  )
}

export function PasswordResetRoute() {
  const { t } = useT("auth")
  usePageTitle(t("password_reset.title"))
  const params = useParams()
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const token = params.token || ""
  const [password, setPassword] = useState("")
  const [passwordConfirmation, setPasswordConfirmation] = useState("")
  const submit = useMutation({
    mutationFn: () => resetPassword(token, { password, password_confirmation: passwordConfirmation }),
    onSuccess: (payload) => assignWithPrefix(prefix, payload.redirect_to)
  })

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    submit.mutate()
  }

  return (
    <AuthShell
      title={t("password_reset.title")}
      subtitle={t("password_reset.subtitle")}
    >
      <form className="space-y-5" onSubmit={onSubmit}>
        {submit.isError ? <PanelMessage tone="error">{errorMessage(submit.error, t("password_reset.error"))}</PanelMessage> : null}
        <Field label={t("field.new_password")}>
          <input
            autoComplete="new-password"
            autoFocus
            className={inputClass()}
            maxLength={72}
            onChange={(event) => setPassword(event.target.value)}
            required
            type="password"
            value={password}
          />
          <PasswordStrengthMeter password={password} />
        </Field>
        <Field label={t("field.confirm_password")}>
          <input
            autoComplete="new-password"
            className={inputClass()}
            maxLength={72}
            onChange={(event) => setPasswordConfirmation(event.target.value)}
            required
            type="password"
            value={passwordConfirmation}
          />
          <PasswordMatchHint confirmation={passwordConfirmation} password={password} />
        </Field>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
          <button className={authPrimaryButtonClass} disabled={submit.isPending} type="submit">
            {submit.isPending ? t("password_reset.submitting") : t("password_reset.submit")}
          </button>
          <Link className="text-sm text-gray-700 dark:text-gray-300 underline hover:no-underline" to={`${prefix}/session/new`}>{t("back_to_sign_in")}</Link>
        </div>
      </form>
    </AuthShell>
  )
}

function AuthShell({ title, subtitle, children }: { title: string; subtitle?: string; children: ReactNode }) {
  // Vertically centered so sign-in reads as a proper entry screen (the
  // desktop shell lands here when signed out); the inner column keeps the
  // familiar max-w-xl card with left-aligned headings.
  return (
    <main aria-label={title} className="flex min-h-[70vh] flex-col items-center justify-center p-6">
      <div className="w-full max-w-xl space-y-6">
        <header>
          <h1 className="text-3xl font-semibold text-gray-900 dark:text-gray-100">{title}</h1>
          {subtitle ? <p className="mt-2 text-sm leading-6 text-gray-600 dark:text-gray-400">{subtitle}</p> : null}
        </header>
        <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-5">
          {children}
        </section>
      </div>
    </main>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
      {label}
      <div className="mt-2">{children}</div>
    </label>
  )
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950/40 text-red-700 dark:text-red-300",
    success: "border-green-200 dark:border-green-800 bg-green-50 dark:bg-green-950/40 text-green-700 dark:text-green-300",
    muted: "border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 text-gray-600 dark:text-gray-400"
  }

  return <div className={`rounded border p-3 text-sm ${colors[tone]}`}>{children}</div>
}

// The JSON auth endpoints return app-root paths ("/onboarding", "/dashboard");
// when the SPA is mounted under /app-shell, keep the user inside that prefix
// instead of bouncing them out to the server-rendered root. Absolute URLs
// pass through verbatim — after_authentication_path can replay a stored
// request.url ("http://host/app-shell/jobs/5"), and gluing the prefix onto
// that would build a broken path. Exported for tests.
export function authRedirectTarget(prefix: string, path: string) {
  if (!prefix || !path.startsWith("/") || path.startsWith(prefix)) return path

  return `${prefix}${path}`
}

function assignWithPrefix(prefix: string, path: string) {
  window.location.assign(authRedirectTarget(prefix, path))
}

