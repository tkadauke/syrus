import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, Row, SectionLabel, StatePill } from "../toolCardUi"
import { Table, TBody, Td, THead } from "../adminToolCard"

// Core-owned tool card for admin_github_app_installation_diagnostic
// (the tool-card work). Surfaces the GitHub App's global registration/JWT
// health, the last installation sync attempt, and a per-repository table of
// credential state and the recommended next action -- the actual fields an
// operator chasing a "why is this repo on PAT fallback" question needs.
type GlobalState = { registered: boolean; jwtUsable: boolean; jwtErrorMessage: string | null }
type LatestSync = { lastAttemptedAt: string | null; lastSuccessfulAt: string | null; errorClass: string | null; errorMessage: string | null }
type InstallationRow = {
  key: string
  accountLogin: string | null
  githubInstallationId: string | null
  installedAt: string | null
  removedAt: string | null
  active: boolean
}
type RepositoryRow = {
  key: string
  slug: string | null
  credentialMode: string | null
  appCredentialActive: boolean
  inactiveReason: string | null
  recommendedNextAction: string | null
}

type DiagnosticCard = {
  global: GlobalState
  latestSync: LatestSync
  installations: InstallationRow[]
  repositories: RepositoryRow[]
  recommendedNextAction: string | null
}

function parseGlobal(value: unknown): GlobalState | null {
  if (!isPlainObject(value)) return null
  return {
    registered: value.registered === true,
    jwtUsable: value.jwt_usable === true,
    jwtErrorMessage: displayValue(value.jwt_error_message)
  }
}

function parseLatestSync(value: unknown): LatestSync | null {
  if (!isPlainObject(value)) return null
  return {
    lastAttemptedAt: displayValue(value.last_attempted_at),
    lastSuccessfulAt: displayValue(value.last_successful_at),
    errorClass: displayValue(value.error_class),
    errorMessage: displayValue(value.error_message)
  }
}

function parseInstallation(value: unknown, index: number): InstallationRow | null {
  if (!isPlainObject(value)) return null
  return {
    key: `${displayValue(value.id) ?? index}`,
    accountLogin: displayValue(value.account_login),
    githubInstallationId: displayValue(value.github_installation_id),
    installedAt: displayValue(value.installed_at),
    removedAt: displayValue(value.removed_at),
    active: value.active === true
  }
}

function parseRepository(value: unknown, index: number): RepositoryRow | null {
  if (!isPlainObject(value)) return null
  const slug = displayValue(value.slug)
  return {
    key: `${displayValue(value.id) ?? index}`,
    slug,
    credentialMode: displayValue(value.credential_mode),
    appCredentialActive: value.app_credential_active === true,
    inactiveReason: displayValue(value.app_credential_inactive_reason),
    recommendedNextAction: displayValue(value.recommended_next_action)
  }
}

function parseDiagnostic(context: ToolCardContext): DiagnosticCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const global = parseGlobal(parsed.global)
  const latestSync = parseLatestSync(parsed.latest_sync)
  if (!global || !latestSync || !Array.isArray(parsed.installations) || !Array.isArray(parsed.repositories)) return null

  return {
    global,
    latestSync,
    installations: parsed.installations.flatMap((installation, index) => {
      const row = parseInstallation(installation, index)
      return row ? [row] : []
    }),
    repositories: parsed.repositories.flatMap((repository, index) => {
      const row = parseRepository(repository, index)
      return row ? [row] : []
    }),
    recommendedNextAction: displayValue(parsed.recommended_next_action)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseDiagnostic(context)
  if (!card) return null

  if (!card.global.registered) return "GitHub App not registered"
  if (card.recommendedNextAction && card.recommendedNextAction !== "none") return `Action needed: ${card.recommendedNextAction.replace(/_/g, " ")}`
  return `${card.repositories.length} repositor${card.repositories.length === 1 ? "y" : "ies"} checked`
}

function renderExpanded(context: ToolCardContext) {
  const card = parseDiagnostic(context)
  if (!card) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={card.global.registered ? "registered" : "not registered"} tone={card.global.registered ? "success" : "failure"} />
        <StatePill state={card.global.jwtUsable ? "jwt usable" : "jwt unusable"} tone={card.global.jwtUsable ? "success" : "failure"} />
        {card.recommendedNextAction && card.recommendedNextAction !== "none" ? <Badge>next: {card.recommendedNextAction.replace(/_/g, " ")}</Badge> : null}
      </div>
      {card.global.jwtErrorMessage ? (
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
          {card.global.jwtErrorMessage}
        </div>
      ) : null}
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Last sync attempt" value={card.latestSync.lastAttemptedAt ?? "—"} />
        <Row label="Last sync success" value={card.latestSync.lastSuccessfulAt ?? "—"} />
      </dl>
      {card.latestSync.errorMessage ? (
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
          {card.latestSync.errorClass ? `${card.latestSync.errorClass}: ` : ""}
          {card.latestSync.errorMessage}
        </div>
      ) : null}
      <div>
        <SectionLabel>Repositories ({card.repositories.length})</SectionLabel>
        {card.repositories.length === 0 ? (
          <EmptyState>No repositories in scope.</EmptyState>
        ) : (
          <Table>
            <THead columns={["Repository", "Credential mode", "App credential", "Inactive reason", "Next action"]} />
            <TBody>
              {card.repositories.map((repository) => (
                <tr key={repository.key}>
                  <Td mono>{repository.slug || "—"}</Td>
                  <Td>{repository.credentialMode || "—"}</Td>
                  <Td>{repository.appCredentialActive ? <StatePill state="active" tone="success" /> : <StatePill state="inactive" tone="warning" />}</Td>
                  <Td maxWidth title={repository.inactiveReason ?? undefined}>
                    {repository.inactiveReason?.replace(/_/g, " ") || "—"}
                  </Td>
                  <Td maxWidth>
                    {repository.recommendedNextAction && repository.recommendedNextAction !== "none"
                      ? repository.recommendedNextAction.replace(/_/g, " ")
                      : "—"}
                  </Td>
                </tr>
              ))}
            </TBody>
          </Table>
        )}
      </div>
      <div>
        <SectionLabel>Installations ({card.installations.length})</SectionLabel>
        {card.installations.length === 0 ? (
          <EmptyState>No installations found.</EmptyState>
        ) : (
          <Table>
            <THead columns={["Account", "Installation id", "Installed", "Removed", "State"]} />
            <TBody>
              {card.installations.map((installation) => (
                <tr key={installation.key}>
                  <Td mono>{installation.accountLogin || "—"}</Td>
                  <Td mono>{installation.githubInstallationId || "—"}</Td>
                  <Td mono>{installation.installedAt || "—"}</Td>
                  <Td mono>{installation.removedAt || "—"}</Td>
                  <Td>{installation.active ? <StatePill state="active" tone="success" /> : <StatePill state="removed" tone="failure" />}</Td>
                </tr>
              ))}
            </TBody>
          </Table>
        )}
      </div>
    </CardShell>
  )
}

const adminGithubAppInstallationDiagnosticToolCard: ToolCardRenderer = {
  toolName: "admin_github_app_installation_diagnostic",
  collapsedSummary,
  renderExpanded
}

export default adminGithubAppInstallationDiagnosticToolCard
