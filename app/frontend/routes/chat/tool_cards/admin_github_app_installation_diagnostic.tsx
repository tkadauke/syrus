import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import type { ReactNode } from "react"
import { redactToolCardText } from "../../../toolCardSecurity"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, Row, SectionLabel, StatePill } from "../toolCardUi"
import { TextPreview } from "../toolCardMarkdown"
import { Table, TBody, Td, THead } from "../adminToolCard"

type Installation = {
  key: string
  id: string | null
  accountLogin: string | null
  accountId: string | null
  accountType: string | null
  githubId: string | null
  installedAt: string | null
  removedAt: string | null
  active: boolean
}
type Membership = {
  key: string
  userId: string | null
  email: string | null
  role: string | null
  installationId: string | null
  effectiveId: string | null
  installation: Installation | null
}
type Repository = {
  key: string
  id: string | null
  slug: string | null
  owner: string | null
  name: string | null
  githubOwnerId: string | null
  githubRepositoryId: string | null
  installationId: string | null
  credentialMode: string | null
  active: boolean
  inactiveReason: string | null
  installUrl: string | null
  installUrlMissingReason: string | null
  installation: Installation | null
  memberships: Membership[]
  action: string | null
}
type Card = {
  global: {
    appId: boolean
    slug: boolean
    privateKey: boolean
    registeredAt: string | null
    registered: boolean
    jwtUsable: boolean
    jwtErrorClass: string | null
    jwtError: string | null
  }
  sync: {
    attemptedAt: string | null
    successfulAt: string | null
    durationMs: string | null
    recordsSeen: string | null
    errorClass: string | null
    error: string | null
  }
  installations: Installation[]
  repositories: Repository[]
  action: string | null
}

const ACTION_HELP: Record<string, string> = {
  refresh_installations: "Refresh GitHub App installations to update the stored installation and repository links.",
  relink_repository_to_existing_active_installation: "Link the repository to the active installation already available for its owner.",
  reinstall_app_for_owner_or_repo: "Reinstall the GitHub App for the repository owner or grant it access to this repository.",
  reselect_repository_to_capture_github_ids: "Select the repository again so Syrus can store the GitHub owner and repository IDs.",
  fallback_to_pat: "No usable App credential was found; keep using the configured PAT until App access is repaired.",
  none: "No operator action is currently recommended."
}

function installation(value: unknown, fallback: string): Installation | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  return {
    key: id ?? fallback,
    id,
    accountLogin: displayValue(value.account_login),
    accountId: displayValue(value.account_id),
    accountType: displayValue(value.account_type),
    githubId: displayValue(value.github_installation_id),
    installedAt: displayValue(value.installed_at),
    removedAt: displayValue(value.removed_at),
    active: value.active === true
  }
}

function membership(value: unknown, index: number): Membership | null {
  if (!isPlainObject(value)) return null
  const userId = displayValue(value.user_id)
  return {
    key: `${userId ?? "member"}-${index}`,
    userId,
    email: displayValue(value.user_email),
    role: displayValue(value.role),
    installationId: displayValue(value.installation_id),
    effectiveId: displayValue(value.effective_client_installation_id),
    installation: installation(value.installation, `member-installation-${index}`)
  }
}

function repository(value: unknown, index: number): Repository | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  return {
    key: id ?? `${displayValue(value.slug) ?? "repository"}-${index}`,
    id,
    slug: displayValue(value.slug),
    owner: displayValue(value.owner),
    name: displayValue(value.name),
    githubOwnerId: displayValue(value.github_owner_id),
    githubRepositoryId: displayValue(value.github_repository_id),
    installationId: displayValue(value.installation_id),
    credentialMode: displayValue(value.credential_mode),
    active: value.app_credential_active === true,
    inactiveReason: displayValue(value.app_credential_inactive_reason),
    installUrl: displayValue(value.scoped_install_url),
    installUrlMissingReason: displayValue(value.install_url_missing_reason),
    installation: installation(value.repository_installation, `repository-installation-${index}`),
    memberships: Array.isArray(value.membership_installations)
      ? value.membership_installations.flatMap((item, itemIndex) => {
          const row = membership(item, itemIndex)
          return row ? [row] : []
        })
      : [],
    action: displayValue(value.recommended_next_action)
  }
}

function parse(context: ToolCardContext): Card | null {
  const value = context.parsedResult
  if (
    !isPlainObject(value) ||
    !isPlainObject(value.global) ||
    !isPlainObject(value.latest_sync) ||
    !Array.isArray(value.installations) ||
    !Array.isArray(value.repositories)
  )
    return null
  const global = value.global
  const sync = value.latest_sync
  return {
    global: {
      appId: global.app_id_present === true,
      slug: global.slug_present === true,
      privateKey: global.private_key_present === true,
      registeredAt: displayValue(global.registered_at),
      registered: global.registered === true,
      jwtUsable: global.jwt_usable === true,
      jwtErrorClass: displayValue(global.jwt_error_class),
      jwtError: displayValue(global.jwt_error_message)
    },
    sync: {
      attemptedAt: displayValue(sync.last_attempted_at),
      successfulAt: displayValue(sync.last_successful_at),
      durationMs: displayValue(sync.duration_ms),
      recordsSeen: displayValue(sync.records_seen),
      errorClass: displayValue(sync.error_class),
      error: displayValue(sync.error_message)
    },
    installations: value.installations.flatMap((item, index) => {
      const row = installation(item, `installation-${index}`)
      return row ? [row] : []
    }),
    repositories: value.repositories.flatMap((item, index) => {
      const row = repository(item, index)
      return row ? [row] : []
    }),
    action: displayValue(value.recommended_next_action)
  }
}

const humanize = (value: string | null) => value?.replace(/_/g, " ") || "—"
const presence = (value: boolean) => <StatePill state={value ? "present" : "missing"} tone={value ? "success" : "failure"} />

function Detail({ children, label }: { children: ReactNode; label: string }) {
  return (
    <div className="grid min-w-0 grid-cols-[8rem_minmax(0,1fr)] gap-2 text-xs">
      <dt className="text-text-muted">{label}</dt>
      <dd className="min-w-0 break-words text-text-primary">{children}</dd>
    </div>
  )
}

function Action({ value }: { value: string | null }) {
  if (!value) return <>—</>
  return (
    <div className="min-w-0 space-y-1">
      <div className="break-words font-medium text-text-primary">{humanize(value)}</div>
      <div className="break-words text-2xs text-text-muted">{ACTION_HELP[value] ?? "Review this diagnostic and update the GitHub App configuration."}</div>
    </div>
  )
}

function Installations({ rows, empty }: { rows: Installation[]; empty: string }) {
  if (rows.length === 0) return <EmptyState>{empty}</EmptyState>
  return (
    <Table responsive>
      <THead columns={["Record id", "Account", "Account id", "Account type", "GitHub installation id", "Installed", "Removed", "State"]} />
      <TBody>
        {rows.map((row) => (
          <tr key={row.key}>
            <Td mono>{row.id || "—"}</Td>
            <Td mono wrap>
              {row.accountLogin || "—"}
            </Td>
            <Td mono>{row.accountId || "—"}</Td>
            <Td>{row.accountType || "—"}</Td>
            <Td mono>{row.githubId || "—"}</Td>
            <Td mono wrap>
              {row.installedAt || "—"}
            </Td>
            <Td mono wrap>
              {row.removedAt || "—"}
            </Td>
            <Td>{row.active ? <StatePill state="active" tone="success" /> : <StatePill state="removed" tone="failure" />}</Td>
          </tr>
        ))}
      </TBody>
    </Table>
  )
}

function Memberships({ rows }: { rows: Membership[] }) {
  if (rows.length === 0) return <EmptyState>No repository memberships found.</EmptyState>
  return (
    <div className="space-y-2">
      {rows.map((row) => (
        <section className="min-w-0 space-y-2 rounded-[var(--radius-panel)] border border-border bg-surface-raised p-2" key={row.key}>
          <dl className="grid gap-1 sm:grid-cols-2">
            <Row label="User id" value={row.userId || "—"} />
            <Row label="Email" value={row.email || "—"} />
            <Row label="Role" value={row.role || "—"} />
            <Row label="Installation id" value={row.installationId || "—"} />
            <Row label="Effective client installation id" value={row.effectiveId || "—"} />
          </dl>
          <div>
            <div className="mb-1 text-2xs font-semibold uppercase text-text-muted">Membership installation</div>
            <Installations empty="No membership installation is linked." rows={row.installation ? [row.installation] : []} />
          </div>
        </section>
      ))}
    </div>
  )
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return "GitHub App installation diagnostic failed"
  const card = parse(context)
  if (!card) return null
  if (!card.global.registered) return "GitHub App not registered"
  if (card.action && card.action !== "none") return `Action needed: ${humanize(card.action)}`
  return `${card.repositories.length} repositor${card.repositories.length === 1 ? "y" : "ies"} checked`
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError)
    return (
      <CardShell>
        <TextPreview maxLines={4} text={redactToolCardText(context.resultBody) || "The diagnostic failed without an error message."} title="Diagnostic error" />
      </CardShell>
    )
  const card = parse(context)
  if (!card) return null
  const jwtError = [card.global.jwtErrorClass, card.global.jwtError].filter(Boolean).join(": ")
  const syncError = [card.sync.errorClass, card.sync.error].filter(Boolean).join(": ")
  return (
    <CardShell>
      <Row label="Requested repository" value={displayValue(context.input?.repository) ?? "All active repositories"} />
      <div>
        <SectionLabel>GitHub App registration</SectionLabel>
        <dl className="grid gap-1 sm:grid-cols-2">
          <Detail label="App id">{presence(card.global.appId)}</Detail>
          <Detail label="App slug">{presence(card.global.slug)}</Detail>
          <Detail label="Private key">{presence(card.global.privateKey)}</Detail>
          <Row label="Registered at" value={card.global.registeredAt ?? "—"} />
          <Detail label="Registration">
            <StatePill state={card.global.registered ? "registered" : "not registered"} tone={card.global.registered ? "success" : "failure"} />
          </Detail>
          <Detail label="JWT">
            <StatePill state={card.global.jwtUsable ? "usable" : "unusable"} tone={card.global.jwtUsable ? "success" : "failure"} />
          </Detail>
        </dl>
        {jwtError ? (
          <div className="mt-2">
            <TextPreview maxLines={3} text={redactToolCardText(jwtError)} title="JWT error" />
          </div>
        ) : null}
      </div>
      <div>
        <SectionLabel>Latest installation sync</SectionLabel>
        <dl className="grid gap-1 sm:grid-cols-2">
          <Row label="Last attempted" value={card.sync.attemptedAt ?? "—"} />
          <Row label="Last successful" value={card.sync.successfulAt ?? "—"} />
          <Row label="Duration (ms)" value={card.sync.durationMs ?? "—"} />
          <Row label="Records seen" value={card.sync.recordsSeen ?? "—"} />
        </dl>
        {syncError ? (
          <div className="mt-2">
            <TextPreview maxLines={3} text={redactToolCardText(syncError)} title="Sync error" />
          </div>
        ) : null}
      </div>
      <div>
        <SectionLabel>Recommended next action</SectionLabel>
        <Action value={card.action} />
      </div>
      <div>
        <SectionLabel>Installations ({card.installations.length})</SectionLabel>
        <Installations empty="No installations found." rows={card.installations} />
      </div>
      <div className="space-y-2">
        <SectionLabel>Repositories ({card.repositories.length})</SectionLabel>
        {card.repositories.length === 0 ? (
          <EmptyState>No repositories in scope.</EmptyState>
        ) : (
          card.repositories.map((repo) => (
            <section className="min-w-0 space-y-2 rounded-[var(--radius-panel)] border border-border bg-surface p-2" key={repo.key}>
              <div className="flex min-w-0 flex-wrap items-center gap-2">
                <EntityReference kind="repository" repositoryId={repo.id} repositorySlug={repo.slug} />
                <StatePill state={repo.active ? "app credential active" : "app credential inactive"} tone={repo.active ? "success" : "warning"} />
                {repo.credentialMode ? <Badge>{repo.credentialMode}</Badge> : null}
              </div>
              <dl className="grid gap-1 sm:grid-cols-2">
                <Row label="Record id" value={repo.id ?? "—"} />
                <Row label="Owner" value={repo.owner ?? "—"} />
                <Row label="Name" value={repo.name ?? "—"} />
                <Row label="GitHub owner id" value={repo.githubOwnerId ?? "—"} />
                <Row label="GitHub repository id" value={repo.githubRepositoryId ?? "—"} />
                <Row label="Installation id" value={repo.installationId ?? "—"} />
                <Detail label="Inactive reason">{humanize(repo.inactiveReason)}</Detail>
                <Detail label="Install URL unavailable reason">{humanize(repo.installUrlMissingReason)}</Detail>
              </dl>
              {repo.installUrl ? (
                <a
                  className="inline-flex min-h-11 items-center break-all font-medium text-brand hover:underline sm:min-h-0"
                  href={repo.installUrl}
                  rel="noreferrer"
                  target="_blank"
                >
                  Open scoped GitHub App installation
                </a>
              ) : null}
              <div>
                <div className="mb-1 text-2xs font-semibold uppercase text-text-muted">Repository installation</div>
                <Installations empty="No repository installation is linked." rows={repo.installation ? [repo.installation] : []} />
              </div>
              <div>
                <div className="mb-1 text-2xs font-semibold uppercase text-text-muted">Membership installations ({repo.memberships.length})</div>
                <Memberships rows={repo.memberships} />
              </div>
              <div>
                <div className="mb-1 text-2xs font-semibold uppercase text-text-muted">Repository next action</div>
                <Action value={repo.action} />
              </div>
            </section>
          ))
        )}
      </div>
    </CardShell>
  )
}

const card: ToolCardRenderer = { toolName: "admin_github_app_installation_diagnostic", collapsedSummary, renderExpanded }
export default card
