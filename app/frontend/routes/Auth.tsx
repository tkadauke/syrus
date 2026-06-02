import { useMutation, useQuery } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"
import {
  fetchSignup,
  requestPasswordReset,
  resetPassword,
  signIn,
  signUp,
  type SignupPayload
} from "../api/auth"

export function SignInRoute() {
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const [emailAddress, setEmailAddress] = useState("")
  const [password, setPassword] = useState("")
  const submit = useMutation({
    mutationFn: () => signIn({ email_address: emailAddress, password }),
    onSuccess: (payload) => window.location.assign(payload.redirect_to)
  })

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    submit.mutate()
  }

  return (
    <AuthShell
      title="Sign in"
      subtitle="Use an existing Syrus account for this instance."
    >
      <form className="space-y-5" onSubmit={onSubmit}>
        {submit.isError ? <PanelMessage tone="error">{errorMessage(submit.error, "Unable to sign in.")}</PanelMessage> : null}
        <Field label="Email address">
          <input
            autoComplete="username"
            autoFocus
            className={inputClass()}
            onChange={(event) => setEmailAddress(event.target.value)}
            required
            type="email"
            value={emailAddress}
          />
        </Field>
        <Field label="Password">
          <input
            autoComplete="current-password"
            className={inputClass()}
            maxLength={72}
            onChange={(event) => setPassword(event.target.value)}
            required
            type="password"
            value={password}
          />
        </Field>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
          <button className={primaryButtonClass()} disabled={submit.isPending} type="submit">
            {submit.isPending ? "Signing in..." : "Sign in"}
          </button>
          <Link className="text-sm text-gray-700 underline hover:no-underline" to={`${prefix}/passwords/new`}>Forgot password?</Link>
        </div>
      </form>
    </AuthShell>
  )
}

export function SignUpRoute() {
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const signup = useQuery({
    queryKey: ["auth", "signup", location.search],
    queryFn: () => fetchSignup(location.search)
  })

  return (
    <AuthShell
      title="Create account"
      subtitle="Join this Syrus instance with open sign-ups or an invitation link."
    >
      {signup.isPending ? <PanelMessage>Loading sign-up...</PanelMessage> : null}
      {signup.isError ? <PanelMessage tone="error">{errorMessage(signup.error, "Unable to load sign-up.")}</PanelMessage> : null}
      {signup.isSuccess ? <SignUpForm payload={signup.data} prefix={prefix} /> : null}
    </AuthShell>
  )
}

function SignUpForm({ payload, prefix }: { payload: SignupPayload; prefix: string }) {
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
    onSuccess: (saved) => window.location.assign(saved.redirect_to)
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
        Sign-up is invitation-only. Use an invitation link or <Link className="underline hover:no-underline" to={`${prefix}/session/new`}>sign in</Link>.
      </PanelMessage>
    )
  }

  return (
    <form className="space-y-5" onSubmit={onSubmit}>
      {payload.invitation ? <PanelMessage>Accepting an invitation from {payload.invitation.invited_by_email}.</PanelMessage> : null}
      {payload.first_signup ? <PanelMessage>No users exist yet. This account will become the administrator.</PanelMessage> : null}
      {submit.isError ? <PanelMessage tone="error">{errorMessage(submit.error, "Unable to create account.")}</PanelMessage> : null}
      <Field label="Email address">
        <input
          autoComplete="username"
          autoFocus
          className={inputClass()}
          onChange={(event) => setEmailAddress(event.target.value)}
          required
          type="email"
          value={emailAddress}
        />
      </Field>
      <Field label="Password">
        <input
          autoComplete="new-password"
          className={inputClass()}
          maxLength={72}
          onChange={(event) => setPassword(event.target.value)}
          required
          type="password"
          value={password}
        />
      </Field>
      <Field label="Confirm password">
        <input
          autoComplete="new-password"
          className={inputClass()}
          maxLength={72}
          onChange={(event) => setPasswordConfirmation(event.target.value)}
          required
          type="password"
          value={passwordConfirmation}
        />
      </Field>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
        <button className={primaryButtonClass()} disabled={submit.isPending} type="submit">
          {submit.isPending ? "Creating..." : "Create account"}
        </button>
        <Link className="text-sm text-gray-700 underline hover:no-underline" to={`${prefix}/session/new`}>Already have an account? Sign in</Link>
      </div>
    </form>
  )
}

export function PasswordRequestRoute() {
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
      title="Reset password"
      subtitle="Enter the email address for your Syrus account."
    >
      <form className="space-y-5" onSubmit={onSubmit}>
        <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
        {submit.isError ? <PanelMessage tone="error">{errorMessage(submit.error, "Unable to request password reset.")}</PanelMessage> : null}
        <Field label="Email address">
          <input
            autoComplete="username"
            autoFocus
            className={inputClass()}
            onChange={(event) => setEmailAddress(event.target.value)}
            required
            type="email"
            value={emailAddress}
          />
        </Field>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
          <button className={primaryButtonClass()} disabled={submit.isPending} type="submit">
            {submit.isPending ? "Sending..." : "Email reset instructions"}
          </button>
          <Link className="text-sm text-gray-700 underline hover:no-underline" to={`${prefix}/session/new`}>Back to sign in</Link>
        </div>
      </form>
    </AuthShell>
  )
}

export function PasswordResetRoute() {
  const params = useParams()
  const token = params.token || ""
  const [password, setPassword] = useState("")
  const [passwordConfirmation, setPasswordConfirmation] = useState("")
  const submit = useMutation({
    mutationFn: () => resetPassword(token, { password, password_confirmation: passwordConfirmation }),
    onSuccess: (payload) => window.location.assign(payload.redirect_to)
  })

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    submit.mutate()
  }

  return (
    <AuthShell
      title="Update password"
      subtitle="Choose a new password for your Syrus account."
    >
      <form className="space-y-5" onSubmit={onSubmit}>
        {submit.isError ? <PanelMessage tone="error">{errorMessage(submit.error, "Unable to update password.")}</PanelMessage> : null}
        <Field label="New password">
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
        </Field>
        <Field label="Confirm password">
          <input
            autoComplete="new-password"
            className={inputClass()}
            maxLength={72}
            onChange={(event) => setPasswordConfirmation(event.target.value)}
            required
            type="password"
            value={passwordConfirmation}
          />
        </Field>
        <button className={primaryButtonClass()} disabled={submit.isPending} type="submit">
          {submit.isPending ? "Saving..." : "Save"}
        </button>
      </form>
    </AuthShell>
  )
}

function AuthShell({ title, subtitle, children }: { title: string; subtitle?: string; children: ReactNode }) {
  return (
    <main aria-label={title} className="mx-auto max-w-xl space-y-6 p-6">
      <header>
        <Link className="text-sm font-medium text-blue-700 underline hover:no-underline" to="/">Syrus overview</Link>
        <h1 className="text-3xl font-semibold text-gray-900">{title}</h1>
        {subtitle ? <p className="mt-2 text-sm leading-6 text-gray-600">{subtitle}</p> : null}
      </header>
      <section className="rounded border border-gray-200 bg-white p-5">
        {children}
      </section>
    </main>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block text-sm font-medium text-gray-700">
      {label}
      <div className="mt-2">{children}</div>
    </label>
  )
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700",
    success: "border-green-200 bg-green-50 text-green-700",
    muted: "border-gray-200 bg-gray-50 text-gray-600"
  }

  return <div className={`rounded border p-3 text-sm ${colors[tone]}`}>{children}</div>
}

function inputClass() {
  return "block w-full rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:outline-blue-600"
}

function primaryButtonClass() {
  return "rounded bg-blue-600 px-3.5 py-2.5 font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300"
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
