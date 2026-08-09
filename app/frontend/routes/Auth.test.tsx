import { fireEvent, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi, afterEach } from "vitest"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import type { ReactNode } from "react"
import { authRedirectTarget, PasswordRequestRoute, PasswordResetRoute, SignInRoute } from "./Auth"
import * as passkey from "../lib/passkey"

function renderAt(path: string, routePath: string, element: ReactNode) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route element={element} path={routePath} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

// jsdom KeyboardEventInit support for modifier flags varies; overriding
// getModifierState on a hand-built event is deterministic. React's synthetic
// event delegates getModifierState to the native event.
function pressKey(element: Element, type: "keydown" | "keyup", capsLock: boolean) {
  const event = new KeyboardEvent(type, { bubbles: true, cancelable: true, key: "a" })
  Object.defineProperty(event, "getModifierState", {
    value: (key: string) => key === "CapsLock" && capsLock
  })
  fireEvent(element, event)
}

describe("SignInRoute", () => {
  it("shows the live email validity hint while typing", () => {
    renderAt("/session/new", "/session/new", <SignInRoute />)

    const hint = screen.getByTestId("email-validity")
    // Query the input once: after typing, the hint text joins the label's
    // accessible name, so the plain "Email address" lookup stops matching.
    const email = screen.getByLabelText("Email address")
    expect(hint.className).toContain("opacity-0")

    fireEvent.change(email, { target: { value: "ada@example" } })
    expect(hint.textContent).toContain("Doesn't look like an email address yet")

    fireEvent.change(email, { target: { value: "ada@example.org" } })
    expect(hint.textContent).toContain("Looks good")
  })

  it("surfaces a caps lock warning under the password field", () => {
    renderAt("/session/new", "/session/new", <SignInRoute />)

    const password = screen.getByLabelText("Password")
    const hint = screen.getByTestId("caps-lock")
    expect(hint.className).toContain("opacity-0")

    pressKey(password, "keydown", true)
    expect(hint.textContent).toContain("Caps Lock is on")
    expect(hint.className).toContain("text-amber-600")

    pressKey(password, "keyup", false)
    expect(hint.className).toContain("opacity-0")
  })
})

describe("SignInRoute passkey button", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("renders the passkey button when passkeys are supported", () => {
    vi.spyOn(passkey, "isPasskeySupported").mockReturnValue(true)
    renderAt("/session/new", "/session/new", <SignInRoute />)

    expect(screen.getByRole("button", { name: "Sign in with passkey" })).toBeInTheDocument()
  })

  it("hides the passkey button when passkeys are not supported", () => {
    vi.spyOn(passkey, "isPasskeySupported").mockReturnValue(false)
    renderAt("/session/new", "/session/new", <SignInRoute />)

    expect(screen.queryByRole("button", { name: "Sign in with passkey" })).toBeNull()
  })

  it("shows an error message when passkey sign-in fails", async () => {
    vi.spyOn(passkey, "isPasskeySupported").mockReturnValue(true)
    vi.spyOn(passkey, "signInWithPasskey").mockRejectedValue(new Error("bad credential"))
    renderAt("/session/new", "/session/new", <SignInRoute />)

    fireEvent.click(screen.getByRole("button", { name: "Sign in with passkey" }))

    expect(await screen.findByText("Passkey sign-in failed. Try your email and password instead.")).toBeInTheDocument()
  })

  it("does not show an error message when user cancels the passkey prompt", async () => {
    vi.spyOn(passkey, "isPasskeySupported").mockReturnValue(true)
    const cancelled = new DOMException("User cancelled", "NotAllowedError")
    vi.spyOn(passkey, "signInWithPasskey").mockRejectedValue(cancelled)
    renderAt("/session/new", "/session/new", <SignInRoute />)

    fireEvent.click(screen.getByRole("button", { name: "Sign in with passkey" }))

    // Give the async handler a chance to run
    await screen.findByRole("button", { name: "Sign in with passkey" })
    expect(screen.queryByText(/Passkey sign-in failed/)).toBeNull()
  })
})

describe("PasswordRequestRoute", () => {
  it("shows the live email validity hint while typing", () => {
    renderAt("/passwords/new", "/passwords/new", <PasswordRequestRoute />)

    const hint = screen.getByTestId("email-validity")
    expect(hint.className).toContain("opacity-0")

    fireEvent.change(screen.getByLabelText("Email address"), { target: { value: "ada@example.org" } })
    expect(hint.textContent).toContain("Looks good")
  })
})

describe("PasswordResetRoute", () => {
  it("offers a way back to sign in", () => {
    renderAt("/passwords/reset-token/edit", "/passwords/:token/edit", <PasswordResetRoute />)

    expect(screen.getByRole("link", { name: "Back to sign in" })).toHaveAttribute("href", "/session/new")
  })

  it("keeps the back link inside the /app-shell prefix", () => {
    renderAt("/app-shell/passwords/reset-token/edit", "/app-shell/passwords/:token/edit", <PasswordResetRoute />)

    expect(screen.getByRole("link", { name: "Back to sign in" })).toHaveAttribute("href", "/app-shell/session/new")
  })
})

describe("authRedirectTarget", () => {
  it("keeps app-root redirects inside the /app-shell prefix", () => {
    expect(authRedirectTarget("/app-shell", "/dashboard")).toBe("/app-shell/dashboard")
  })

  it("leaves already-prefixed paths alone", () => {
    expect(authRedirectTarget("/app-shell", "/app-shell/onboarding")).toBe("/app-shell/onboarding")
  })

  it("passes absolute URLs through verbatim", () => {
    // after_authentication_path can replay session[:return_to_after_authenticating],
    // which is stored as the full request.url; prefixing it would build
    // "/app-shellhttp://..." and 404.
    expect(authRedirectTarget("/app-shell", "http://127.0.0.1:3000/app-shell/jobs/5"))
      .toBe("http://127.0.0.1:3000/app-shell/jobs/5")
  })

  it("is a no-op outside the shell", () => {
    expect(authRedirectTarget("", "/dashboard")).toBe("/dashboard")
  })
})
