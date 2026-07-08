import { passwordStrength } from "../lib/passwordStrength"
import { useT } from "../hooks/useT"

// Live feedback under the signup / password-reset fields: an email format
// hint, a four-segment entropy meter that fills and recolors as the
// password grows, and a match hint that fades in on the confirmation
// field. Guidance only — none of it blocks submission.

const EMAIL_SHAPE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/

export function EmailValidityHint({ email }: { email: string }) {
  const { t } = useT("common")
  const valid = email.length > 0 && EMAIL_SHAPE.test(email)
  const invalid = email.length > 0 && !valid

  return (
    <p
      aria-live="polite"
      className={`mt-1 flex items-center gap-1.5 text-xs transition-opacity duration-300 ${
        valid
          ? "text-emerald-600 dark:text-emerald-400 opacity-100"
          : invalid
            ? "text-amber-600 dark:text-amber-400 opacity-100"
            : "opacity-0"
      }`}
      data-testid="email-validity"
    >
      {valid ? (
        <svg aria-hidden="true" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="2.5" viewBox="0 0 24 24">
          <path d="M5 13l4 4L19 7" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      ) : null}
      {valid ? t("email_validity.valid") : invalid ? t("email_validity.invalid") : " "}
    </p>
  )
}

// Sign-in has no use for a strength meter (the password already exists);
// the useful live signal there is Caps Lock, the classic "why is my correct
// password wrong" trap. Same fade-in language as the other hints.
export function CapsLockHint({ active }: { active: boolean }) {
  const { t } = useT("common")
  return (
    <p
      aria-live="polite"
      className={`mt-1 flex items-center gap-1.5 text-xs transition-opacity duration-300 ${
        active ? "text-amber-600 dark:text-amber-400 opacity-100" : "opacity-0"
      }`}
      data-testid="caps-lock"
    >
      {active ? (
        <svg aria-hidden="true" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="2" viewBox="0 0 24 24">
          <path d="M12 9v4m0 4h.01M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      ) : null}
      {active ? t("caps_lock.active") : " "}
    </p>
  )
}

const BAR_COLORS: Record<number, string> = {
  1: "bg-red-400",
  2: "bg-amber-400",
  3: "bg-emerald-400",
  4: "bg-emerald-500"
}

const LABEL_COLORS: Record<number, string> = {
  1: "text-red-600 dark:text-red-400",
  2: "text-amber-600 dark:text-amber-400",
  3: "text-emerald-600 dark:text-emerald-400",
  4: "text-emerald-600 dark:text-emerald-400"
}

const STRENGTH_KEYS: Record<number, string> = {
  1: "password_strength.weak",
  2: "password_strength.fair",
  3: "password_strength.good",
  4: "password_strength.strong"
}

export function PasswordStrengthMeter({ password }: { password: string }) {
  const { t } = useT("common")
  const strength = passwordStrength(password)

  return (
    <div aria-live="polite" className="mt-2" data-testid="password-strength">
      <div className="flex gap-1">
        {[1, 2, 3, 4].map((segment) => (
          <div
            className={`h-1 flex-1 rounded-full transition-colors duration-300 ${
              segment <= strength.score ? BAR_COLORS[strength.score] : "bg-gray-200 dark:bg-gray-700"
            }`}
            key={segment}
          />
        ))}
      </div>
      {/* Non-breaking space keeps the line height stable so the form doesn't jump. */}
      <p className={`mt-1 text-xs transition-colors duration-300 ${LABEL_COLORS[strength.score] ?? "text-gray-400"}`}>
        {strength.score > 0 ? t(STRENGTH_KEYS[strength.score]) : " "}
      </p>
    </div>
  )
}

export function PasswordMatchHint({ password, confirmation }: { password: string; confirmation: string }) {
  const { t } = useT("common")
  const match = confirmation.length > 0 && password === confirmation
  const mismatch = confirmation.length > 0 && !match

  return (
    <p
      aria-live="polite"
      className={`mt-1 flex items-center gap-1.5 text-xs transition-opacity duration-300 ${
        match
          ? "text-emerald-600 dark:text-emerald-400 opacity-100"
          : mismatch
            ? "text-amber-600 dark:text-amber-400 opacity-100"
            : "opacity-0"
      }`}
      data-testid="password-match"
    >
      {match ? (
        <svg aria-hidden="true" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="2.5" viewBox="0 0 24 24">
          <path d="M5 13l4 4L19 7" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      ) : null}
      {match ? t("password_match.match") : mismatch ? t("password_match.mismatch") : " "}
    </p>
  )
}
