# Windows code signing (Azure Artifact Signing)

Background and the decision rationale live in
[`windows-desktop-plan.md`](./windows-desktop-plan.md#code-signing-researched-july-2026).
This doc is the concrete setup runbook: portal steps once, then the repo
secrets that make `release.yml`'s `build-windows` job (and the
`sign-windows-test.yml` manual-dispatch harness) sign real installers.

Azure Artifact Signing (formerly "Trusted Signing") is Microsoft's
low-friction alternative to a traditional Authenticode certificate: $9.99/mo,
identity-validated once (government ID + selfie, ~1 business day), no
hardware token, and CI-friendly (client-secret auth, no local HSM). As of
2026 it's open to individual developers in the US and Canada.

## 1. Azure subscription

You need a **Pay-As-You-Go** subscription — free/trial subscriptions are
rejected for identity validation.

1. Sign in to <https://portal.azure.com> with the Microsoft account you want
   to hold this under (a personal/consumer account is fine).
2. Search "Subscriptions" → **Add** → **Pay-As-You-Go**. Enter a payment
   method. (If you only see "Start free" flows, go to
   <https://azure.microsoft.com/free> instead and choose the pay-as-you-go
   option there — it provisions your default directory more reliably than
   navigating to the portal cold.)
3. **Billing name and address must exactly match your government ID** —
   identity validation cross-checks these. Fix them now
   (Subscriptions → your sub → **Billing profile**) if they're off.

## 2. Create the Artifact Signing account

1. Portal search bar → **"Trusted Signing Accounts"** (the resource is
   still labeled this in some portal blades even though the product is
   branded "Azure Artifact Signing").
2. **Create** → pick a **Resource group** (create one, e.g. `syrus-signing`)
   and a **region** close to you (e.g. `East US`) — this fixes your
   `endpoint` URL for good (`https://<region>.codesigning.azure.net`, e.g.
   `eus` for East US). Note the exact region you pick.
3. Name the account (e.g. `syrus-signing`). Create it — takes under a
   minute.

## 3. Identity validation

0. **Grant yourself the verifier role first** — being subscription Owner
   is NOT enough; the identity-validation blade needs a data-plane role
   and shows "Please ensure you have the 'Artifact Signing Identity
   Verifier' role assigned" until you have it. In the signing account →
   **Access control (IAM)** → **Add role assignment** → role
   **"Trusted Signing Identity Verifier"** (a.k.a. Artifact Signing
   Identity Verifier) → member: your own account → Review + assign.
   Propagation takes a minute or two; Refresh the blade until
   **New identity** enables.
1. Inside the new account, go to **Identity validation** → **New identity**.
2. Choose **Individual**. Enter your legal name/address exactly as on your
   ID, matching the billing profile from step 1.
3. Complete the ID + selfie verification flow (AU10TIX/Entra Verified ID —
   you'll get a link, usually via email, to do this on your phone).
4. Wait for approval (historically same-day to ~1 business day). You'll see
   the validation move to **Completed** in the portal.
   **This expires every 2 years — put a reminder in your calendar**, or
   signing will silently stop working when it lapses.

## 4. Certificate profile

1. Inside the signing account → **Certificate profiles** → **Create**.
2. Profile type: **Public Trust** (this is what gives you a
   publicly-trusted Authenticode signature, as opposed to "Private Trust"
   which is for internal-only distribution).
3. Link it to the identity validation from step 3.
4. Note the **exact certificate profile name** and the **Subject/CN name**
   it issues — the CN is usually your validated legal name. You need this
   **byte-for-byte** later as `publisherName`; a mismatch fails signing.

## 5. Service principal for CI (no interactive login in Actions)

1. Portal search → **Microsoft Entra ID** → **App registrations** →
   **New registration**. Name it e.g. `syrus-release-ci`. Supported
   account types MUST stay on the default, **"Accounts in this
   organizational directory only"** (single tenant) — picking
   **"Personal Microsoft accounts only"** registers the app outside your
   directory, so it never shows up in the IAM member picker in step 4
   below and client-secret auth against your tenant fails. If you
   already created it with the wrong type, delete it and re-register
   (the client ID and secret change; the tenant ID doesn't). Leave
   **Redirect URI** empty — CI uses the client-credentials flow, which
   has no interactive login and no redirect. Register.
2. From the app's **Overview** page, copy:
   - **Application (client) ID** → `AZURE_CLIENT_ID`
   - **Directory (tenant) ID** → `AZURE_TENANT_ID`
3. **Certificates & secrets** → **New client secret** → copy the secret
   **value** immediately (it's hidden after you leave the page) →
   `AZURE_CLIENT_SECRET`.
4. Grant that app permission to sign: go back to your Trusted Signing
   Account (step 2) → **Access control (IAM)** → **Add role assignment** →
   role **"Trusted Signing Certificate Profile Signer"** → **Members** tab →
   **Assign access to: "User, group, or service principal"** (NOT
   "Managed identity" — a managed identity is a different Azure object,
   auto-created and tied to an Azure resource like a VM; an App
   Registration is a service principal, so it only shows up under the
   first option) → **Select members** → search the app registration's
   name (e.g. `syrus-release-ci`) → select it → Review + assign.
   Assigning the role to your own user account instead does nothing for
   CI: the workflow authenticates as the app registration, not as you.
   If the app doesn't appear in the picker, it was almost certainly
   registered with the wrong account type — see step 1.

## 6. Repo secrets

Add these under the repo's **Settings → Secrets and variables → Actions →
Secrets** (on whichever repo runs the workflow — currently `tkadauke/syrus`
for `release.yml`; use your fork for `sign-windows-test.yml` if
you're testing there first):

| Secret | Value | Sensitive? |
| --- | --- | --- |
| `AZURE_TENANT_ID` | Directory (tenant) ID from step 5 | Not secret, but keep with the others |
| `AZURE_CLIENT_ID` | Application (client) ID from step 5 | Not secret, but keep with the others |
| `AZURE_CLIENT_SECRET` | The client secret **value** from step 5 | **Secret** — rotates, don't reuse elsewhere |
| `AZURE_SIGN_ENDPOINT` | `https://<region-code>.codesigning.azure.net` from step 2 | Not secret |
| `AZURE_SIGN_ACCOUNT_NAME` | The signing account name from step 2 | Not secret |
| `AZURE_SIGN_CERT_PROFILE` | The certificate profile name from step 4 | Not secret |
| `AZURE_SIGN_PUBLISHER_NAME` | The exact CN from step 4 | Not secret |

None of the last five are truly sensitive (they're account identifiers, not
credentials). The four `AZURE_SIGN_*` values may live as **Secrets or as
Variables** — the workflow reads Secrets first and falls back to Variables,
so either page works. The first three are real credentials and must be
Secrets. The client secret is the only one that actually gates signing
access. The endpoint is normalized in the workflow, so a trailing slash
copied from the portal is harmless.

The first three (`AZURE_TENANT_ID`/`AZURE_CLIENT_ID`/`AZURE_CLIENT_SECRET`)
are read directly by the Azure SDK's `EnvironmentCredential` — nothing in
this repo needs to reference them by name. The other four are threaded
into `electron-builder`'s `win.azureSignOptions` via CLI dot-path overrides
in the workflow (see `sign-windows-test.yml`) — **not** committed as static
YAML in `desktop/electron-builder.yml`, because the mere presence of
`azureSignOptions` makes electron-builder attempt Azure signing
unconditionally (unlike the macOS `CSC_LINK` path, there's no
"absent → skip silently" fallback), which would break every unsigned
local/dev Windows cross-build done on this Mac.

## 7. Test it

Run **Actions → Sign Windows build (test) → Run workflow** (manual
dispatch only — this never fires automatically). It builds both archs,
signs via Azure, and runs `Get-AuthenticodeSignature` to verify the result
is `Valid` before uploading the installers as a workflow artifact.

**GitHub gotcha: `workflow_dispatch` workflows only appear in the Actions
tab when the workflow file exists on the repository's default branch.**
While this file lives only on a feature branch, the button simply isn't
there (and `gh workflow run` can't find it either). Until the branch
merges, test from a fork: push the feature branch to the fork's `main`
(`git push <fork> <branch>:main --force` — fine when the fork's main has
nothing unique), add the same secrets/variables to the fork, and dispatch
there. The signing account doesn't care which repo the request comes
from — only the Azure credentials matter.

Prerequisites worth double-checking before the first run: identity
validation shows **Completed**, the certificate profile shows **Active**,
and `AZURE_SIGN_PUBLISHER_NAME` matches the profile's certificate CN
byte-for-byte (shown on the certificate profile page).

## 8. Local signing (and why it doesn't work from this Mac)

Unlike macOS signing, there is no working local-signing path for Windows
from a non-Windows host. `win.azureSignOptions` shells out to Azure's
`Invoke-TrustedSigning` PowerShell module, which requires an actual Windows
machine — there's no macOS/Linux client for electron-builder's built-in
integration. So a Windows `.exe` cross-built on this Mac stays unsigned
regardless of what credentials are on disk; `windows-latest` in CI (or a
real Windows box, if one ever enters the picture) is the only place
signing actually happens today.

The plumbing is still in place for that day: `bin/signing-env`'s
`syrus_load_windows_signing_env` reads
`~/.config/syrus/windows-signing.env` (same seven vars as the repo secrets
table above) and exports them — but only when `uname -s` reports a genuine
Windows shell (Git Bash/WSL's `MINGW*`/`MSYS*`/`CYGWIN*`); it's a silent
no-op on Darwin/Linux so it can't produce a false sense of "signed" here.
`bin/release-desktop` doesn't cross-build a Windows target at all today
(no `--win` wiring), so this only matters once that lands.

## 9. Going live (done — July 2026)

`release.yml` now carries a `build-windows` job: on every
`vX.Y.Z` tag it builds, Azure-signs, and publishes the Windows NSIS
installers alongside the mac DMGs (sequenced after the mac job so both
publish into one GitHub release). The Azure configuration from §6 is
required — the job's guard refuses to publish an unsigned Windows
release, and a token-acquisition preflight fails in seconds instead of
after a full build. `sign-windows-test.yml` remains the manual-dispatch
workflow for validating the Azure setup without touching the live
release cadence.
