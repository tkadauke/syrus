import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useState, type FormEvent, type ReactNode } from "react"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { NoticeToast } from "@app/components/NoticeToast"
import { Button, DataTable, DescriptionList, Form } from "@app/components/ui"
import { errorMessage } from "@app/lib/errorMessage"
import {
  createMysqlConnection,
  deleteMysqlConnection,
  fetchMysqlConnections,
  testDraftMysqlConnection,
  testMysqlConnection,
  updateMysqlConnection,
  type MysqlConnectionInput,
  type MysqlConnectionRow,
  type MysqlConnectionTestResult
} from "../api/mysqlConnections"
import {
  fetchMysqlDatabases,
  fetchMysqlTableDetail,
  fetchMysqlTables,
  type MysqlColumn,
  type MysqlForeignKey,
  type MysqlIndex,
  type MysqlSection,
  type MysqlTableDetailResponse
} from "../api/mysqlSchema"
import { MysqlContentTab } from "../components/MysqlContentTab"
import { MysqlQueryTab } from "../components/MysqlQueryTab"
import { MysqlLiveTab } from "../components/MysqlLiveTab"
import { MysqlQueryBuilderTab } from "../components/MysqlQueryBuilderTab"

const queryKey = ["mysql_db_browser", "connections"] as const

const EMPTY_FORM: MysqlConnectionInput = {
  label: "",
  host: "",
  port: 3306,
  username: "",
  default_database: "",
  agentic_access_enabled: false,
  allow_writes: false,
  password: ""
}

type BrowseTarget = { connectionId: number; label: string }

export function MysqlConnections() {
  const { t } = useT("mysql_db_browser")
  usePageTitle(t("heading"))
  const [notice, setNotice] = useState<string | null>(null)
  const [browsing, setBrowsing] = useState<BrowseTarget | null>(null)
  const connections = useQuery({
    queryKey,
    queryFn: fetchMysqlConnections
  })

  if (browsing) {
    return (
      <main aria-label={t("aria_page")} className="mx-auto flex h-full max-w-[96rem] flex-col gap-6 overflow-hidden p-3 sm:p-6">
        <SchemaBrowser connectionId={browsing.connectionId} label={browsing.label} onBack={() => setBrowsing(null)} />
      </main>
    )
  }

  return (
    <main aria-label={t("aria_page")} className="mx-auto flex h-full max-w-[96rem] flex-col gap-6 overflow-hidden p-3 sm:p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("heading")}</h1>
        <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{t("description")}</p>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />

      {connections.isPending ? <Panel>{t("loading")}</Panel> : null}
      {connections.isError ? <Panel tone="error">{errorMessage(connections.error, t("error_loading"))}</Panel> : null}
      {connections.isSuccess ? (
        <>
          <ConnectionCreateForm onNotice={setNotice} />
          <ConnectionsTable
            connections={connections.data.mysql_connections}
            onBrowse={(connection) => setBrowsing({ connectionId: connection.id, label: connection.label })}
            onNotice={setNotice}
          />
        </>
      ) : null}
    </main>
  )
}

function ConnectionCreateForm({ onNotice }: { onNotice: (message: string | null) => void }) {
  const { t } = useT("mysql_db_browser")
  const queryClient = useQueryClient()
  const [values, setValues] = useState<MysqlConnectionInput>(EMPTY_FORM)
  const create = useMutation({
    mutationFn: () => createMysqlConnection(values),
    onSuccess: (payload) => {
      void queryClient.invalidateQueries({ queryKey })
      onNotice(t("created_notice", { label: payload.mysql_connection.label }))
      setValues(EMPTY_FORM)
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    create.mutate()
  }

  return (
    <section className="rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950 p-4">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("add_heading")}</h2>
      <form className="mt-3 space-y-3" onSubmit={submit}>
        <ConnectionFieldsGrid idPrefix="new-connection" onChange={setValues} passwordRequired values={values} />
        <Form.Actions align="start" className="pt-0">
          <Button disabled={create.isPending} type="submit" variant="primary">
            {create.isPending ? t("creating") : t("create_button")}
          </Button>
          <TestButton onTest={() => testDraftMysqlConnection(values)} />
        </Form.Actions>
      </form>
      {create.isError ? <p className="mt-3 text-sm text-danger-text" role="alert">{errorMessage(create.error, t("create_error_fallback"))}</p> : null}
    </section>
  )
}

function ConnectionsTable({
  connections,
  onBrowse,
  onNotice
}: {
  connections: MysqlConnectionRow[]
  onBrowse: (connection: MysqlConnectionRow) => void
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("mysql_db_browser")
  const [editingId, setEditingId] = useState<number | null>(null)
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)

  if (!isDesktop) {
    return (
      <section className="rounded border border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
        {connections.length === 0 ? (
          <p className="px-4 py-6 text-center text-sm text-gray-500 dark:text-gray-400">{t("empty")}</p>
        ) : (
          <div className="divide-y divide-gray-100 dark:divide-gray-900">
            {connections.map((connection) => (
              editingId === connection.id ? (
                <MobileConnectionEditCard
                  connection={connection}
                  key={connection.id}
                  onCancel={() => setEditingId(null)}
                  onNotice={onNotice}
                  onSaved={() => setEditingId(null)}
                />
              ) : (
                <MobileConnectionCard
                  connection={connection}
                  key={connection.id}
                  onBrowse={() => onBrowse(connection)}
                  onEdit={() => setEditingId(connection.id)}
                  onNotice={onNotice}
                />
              )
            ))}
          </div>
        )}
      </section>
    )
  }

  return (
    <section>
      <DataTable.Root>
        <DataTable.Header>
          <DataTable.Row>
            <DataTable.HeadCell>{t("col_label")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_host")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_username")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_default_database")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_password")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_agentic_access")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_allow_writes")}</DataTable.HeadCell>
            <DataTable.HeadCell><span className="sr-only">{t("col_actions")}</span></DataTable.HeadCell>
          </DataTable.Row>
        </DataTable.Header>
        <DataTable.Body>
            {connections.length === 0 ? (
              <DataTable.Empty colSpan={8}>{t("empty")}</DataTable.Empty>
            ) : connections.map((connection) => (
              editingId === connection.id ? (
                <ConnectionEditRow
                  connection={connection}
                  key={connection.id}
                  onCancel={() => setEditingId(null)}
                  onNotice={onNotice}
                  onSaved={() => setEditingId(null)}
                />
              ) : (
                <ConnectionRow
                  connection={connection}
                  key={connection.id}
                  onBrowse={() => onBrowse(connection)}
                  onEdit={() => setEditingId(connection.id)}
                  onNotice={onNotice}
                />
              )
            ))}
        </DataTable.Body>
      </DataTable.Root>
    </section>
  )
}

function ConnectionRow({
  connection,
  onBrowse,
  onEdit,
  onNotice
}: {
  connection: MysqlConnectionRow
  onBrowse: () => void
  onEdit: () => void
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("mysql_db_browser")

  return (
    <DataTable.Row>
      <DataTable.Cell className="font-medium text-gray-900 dark:text-gray-100">{connection.label}</DataTable.Cell>
      <DataTable.Cell className="font-mono text-gray-700 dark:text-gray-300">{connection.host}:{connection.port}</DataTable.Cell>
      <DataTable.Cell className="text-gray-700 dark:text-gray-300">{connection.username}</DataTable.Cell>
      <DataTable.Cell className="text-gray-700 dark:text-gray-300">{connection.default_database || "-"}</DataTable.Cell>
      <DataTable.Cell>
        <StatusBadge tone={connection.has_password ? "success" : "neutral"}>
          {connection.has_password ? t("has_password_yes") : t("has_password_no")}
        </StatusBadge>
      </DataTable.Cell>
      <DataTable.Cell>
        <StatusBadge tone={connection.agentic_access_enabled ? "success" : "neutral"}>
          {connection.agentic_access_enabled ? t("agentic_enabled") : t("agentic_disabled")}
        </StatusBadge>
      </DataTable.Cell>
      <DataTable.Cell>
        <StatusBadge tone={connection.allow_writes ? "warning" : "neutral"}>
          {connection.allow_writes ? t("allow_writes_enabled") : t("allow_writes_disabled")}
        </StatusBadge>
      </DataTable.Cell>
      <DataTable.Cell>
        <ConnectionActions align="end" connection={connection} onBrowse={onBrowse} onEdit={onEdit} onNotice={onNotice} />
      </DataTable.Cell>
    </DataTable.Row>
  )
}

function MobileConnectionCard({
  connection,
  onBrowse,
  onEdit,
  onNotice
}: {
  connection: MysqlConnectionRow
  onBrowse: () => void
  onEdit: () => void
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("mysql_db_browser")

  return (
    <article className="space-y-3 px-4 py-4">
      <div>
        <p className="font-medium text-gray-900 dark:text-gray-100">{connection.label}</p>
        <p className="font-mono text-xs text-gray-500 dark:text-gray-400">{connection.host}:{connection.port}</p>
      </div>
      <DescriptionList.Root className="grid-cols-2 text-xs sm:grid-cols-2" density="compact">
        <MobileField label={t("col_username")} value={connection.username} />
        <MobileField label={t("col_default_database")} value={connection.default_database || "-"} />
        <MobileField label={t("col_password")}>
          <StatusBadge tone={connection.has_password ? "success" : "neutral"}>
            {connection.has_password ? t("has_password_yes") : t("has_password_no")}
          </StatusBadge>
        </MobileField>
        <MobileField label={t("col_agentic_access")}>
          <StatusBadge tone={connection.agentic_access_enabled ? "success" : "neutral"}>
            {connection.agentic_access_enabled ? t("agentic_enabled") : t("agentic_disabled")}
          </StatusBadge>
        </MobileField>
        <MobileField label={t("col_allow_writes")}>
          <StatusBadge tone={connection.allow_writes ? "warning" : "neutral"}>
            {connection.allow_writes ? t("allow_writes_enabled") : t("allow_writes_disabled")}
          </StatusBadge>
        </MobileField>
      </DescriptionList.Root>
      <ConnectionActions align="start" connection={connection} onBrowse={onBrowse} onEdit={onEdit} onNotice={onNotice} />
    </article>
  )
}

function MobileField({ children, label, value }: { children?: ReactNode; label: string; value?: string }) {
  return (
    <DescriptionList.Item descriptionClassName="truncate text-xs text-gray-700 dark:text-gray-300" label={label} termClassName="text-[10px]">
      {children ?? value}
    </DescriptionList.Item>
  )
}

function ConnectionActions({
  align,
  connection,
  onBrowse,
  onEdit,
  onNotice
}: {
  align: "start" | "end"
  connection: MysqlConnectionRow
  onBrowse: () => void
  onEdit: () => void
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("mysql_db_browser")
  const queryClient = useQueryClient()
  const destroy = useMutation({
    mutationFn: () => deleteMysqlConnection(connection.id),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey })
      onNotice(t("deleted_notice", { label: connection.label }))
    }
  })

  return (
    <div>
      <div className={`flex flex-wrap items-start gap-2 ${align === "end" ? "justify-end" : ""}`}>
        <Button onClick={onBrowse} type="button" variant="primary">
          {t("browse_button")}
        </Button>
        <TestButton onTest={() => testMysqlConnection(connection.id)} />
        <Button onClick={onEdit} type="button" variant="secondary">
          {t("edit_button")}
        </Button>
        <Button
          disabled={destroy.isPending}
          onClick={() => {
            if (window.confirm(t("confirm_delete", { label: connection.label }))) {
              onNotice(null)
              destroy.mutate()
            }
          }}
          type="button"
          variant="danger"
        >
          {destroy.isPending ? t("deleting") : t("delete_button")}
        </Button>
      </div>
      {destroy.isError ? (
        <p className={`mt-2 text-xs text-danger-text ${align === "end" ? "text-right" : ""}`} role="alert">
          {errorMessage(destroy.error, t("delete_error_fallback"))}
        </p>
      ) : null}
    </div>
  )
}

function ConnectionEditForm({
  connection,
  onCancel,
  onNotice,
  onSaved
}: {
  connection: MysqlConnectionRow
  onCancel: () => void
  onNotice: (message: string | null) => void
  onSaved: () => void
}) {
  const { t } = useT("mysql_db_browser")
  const queryClient = useQueryClient()
  const [values, setValues] = useState<MysqlConnectionInput>({
    label: connection.label,
    host: connection.host,
    port: connection.port,
    username: connection.username,
    default_database: connection.default_database || "",
    agentic_access_enabled: connection.agentic_access_enabled,
    allow_writes: connection.allow_writes,
    password: ""
  })
  const update = useMutation({
    mutationFn: () => updateMysqlConnection(connection.id, values),
    onSuccess: (payload) => {
      void queryClient.invalidateQueries({ queryKey })
      onNotice(t("updated_notice", { label: payload.mysql_connection.label }))
      onSaved()
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    update.mutate()
  }

  return (
    <form className="space-y-3" onSubmit={submit}>
      <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("edit_heading")}</h3>
      <ConnectionFieldsGrid
        idPrefix={`edit-connection-${connection.id}`}
        onChange={setValues}
        passwordHint={t("field_password_hint_edit")}
        values={values}
      />
      <Form.Actions align="start" className="pt-0">
        <Button disabled={update.isPending} type="submit" variant="primary">
          {update.isPending ? t("saving") : t("save_button")}
        </Button>
        <Button onClick={onCancel} type="button" variant="secondary">
          {t("cancel_button")}
        </Button>
        <TestButton onTest={() => testMysqlConnection(connection.id, values.password || undefined)} />
      </Form.Actions>
      {update.isError ? <p className="text-sm text-danger-text" role="alert">{errorMessage(update.error, t("update_error_fallback"))}</p> : null}
    </form>
  )
}

function ConnectionEditRow({
  connection,
  onCancel,
  onNotice,
  onSaved
}: {
  connection: MysqlConnectionRow
  onCancel: () => void
  onNotice: (message: string | null) => void
  onSaved: () => void
}) {
  return (
    <DataTable.Row>
      <DataTable.Cell colSpan={8}>
        <ConnectionEditForm connection={connection} onCancel={onCancel} onNotice={onNotice} onSaved={onSaved} />
      </DataTable.Cell>
    </DataTable.Row>
  )
}

function MobileConnectionEditCard({
  connection,
  onCancel,
  onNotice,
  onSaved
}: {
  connection: MysqlConnectionRow
  onCancel: () => void
  onNotice: (message: string | null) => void
  onSaved: () => void
}) {
  return (
    <div className="px-4 py-4">
      <ConnectionEditForm connection={connection} onCancel={onCancel} onNotice={onNotice} onSaved={onSaved} />
    </div>
  )
}

function ConnectionFieldsGrid({
  idPrefix,
  onChange,
  passwordHint,
  passwordRequired,
  values
}: {
  idPrefix: string
  onChange: (values: MysqlConnectionInput) => void
  passwordHint?: string
  passwordRequired?: boolean
  values: MysqlConnectionInput
}) {
  const { t } = useT("mysql_db_browser")

  function set<K extends keyof MysqlConnectionInput>(key: K, value: MysqlConnectionInput[K]) {
    onChange({ ...values, [key]: value })
  }

  return (
    <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
      <Form.Field controlId={`${idPrefix}-label`}>
        <Form.Label>{t("field_label")}</Form.Label>
        <Form.Input
          onChange={(event) => set("label", event.target.value)}
          required
          type="text"
          value={values.label}
        />
      </Form.Field>
      <Form.Field controlId={`${idPrefix}-host`}>
        <Form.Label>{t("field_host")}</Form.Label>
        <Form.Input
          onChange={(event) => set("host", event.target.value)}
          required
          type="text"
          value={values.host}
        />
      </Form.Field>
      <Form.Field controlId={`${idPrefix}-port`}>
        <Form.Label>{t("field_port")}</Form.Label>
        <Form.Input
          max={65535}
          min={1}
          onChange={(event) => set("port", Number(event.target.value))}
          required
          type="number"
          value={values.port}
        />
      </Form.Field>
      <Form.Field controlId={`${idPrefix}-username`}>
        <Form.Label>{t("field_username")}</Form.Label>
        <Form.Input
          onChange={(event) => set("username", event.target.value)}
          required
          type="text"
          value={values.username}
        />
      </Form.Field>
      <Form.Field controlId={`${idPrefix}-password`}>
        <Form.Label>{t("field_password")}</Form.Label>
        <Form.Input
          autoComplete="new-password"
          onChange={(event) => set("password", event.target.value)}
          required={passwordRequired}
          type="password"
          value={values.password ?? ""}
        />
        {passwordHint ? <Form.HelpText>{passwordHint}</Form.HelpText> : null}
      </Form.Field>
      <Form.Field controlId={`${idPrefix}-default-database`}>
        <Form.Label>
          {t("field_default_database")} <span className="font-normal text-text-muted">{t("field_default_database_optional")}</span>
        </Form.Label>
        <Form.Input
          onChange={(event) => set("default_database", event.target.value)}
          type="text"
          value={values.default_database}
        />
      </Form.Field>
      <Form.Field className="sm:col-span-2 lg:col-span-3" controlId={`${idPrefix}-agentic-access`}>
        <Form.Checkbox
          checked={values.agentic_access_enabled}
          className="mt-0.5 rounded border-gray-300 dark:border-gray-600"
          label={t("field_agentic_access")}
          onChange={(event) => set("agentic_access_enabled", event.target.checked)}
        />
        <Form.HelpText>{t("field_agentic_access_hint")}</Form.HelpText>
      </Form.Field>
      <Form.Field className="sm:col-span-2 lg:col-span-3" controlId={`${idPrefix}-allow-writes`}>
        <Form.Checkbox
          checked={values.allow_writes}
          className="mt-0.5 rounded border-gray-300 dark:border-gray-600"
          label={t("field_allow_writes")}
          onChange={(event) => set("allow_writes", event.target.checked)}
        />
        <Form.HelpText>{t("field_allow_writes_hint")}</Form.HelpText>
      </Form.Field>
    </div>
  )
}

function TestButton({ onTest }: { onTest: () => Promise<MysqlConnectionTestResult> }) {
  const { t } = useT("mysql_db_browser")
  const test = useMutation({ mutationFn: onTest })

  return (
    <div className="flex flex-col items-start gap-1">
      <Button disabled={test.isPending} onClick={() => test.mutate()} type="button" variant="secondary">
        {test.isPending ? t("testing") : t("test_button")}
      </Button>
      {test.isSuccess ? (
        test.data.success ? (
          <p className="text-xs text-emerald-700 dark:text-emerald-300">{t("test_success")}</p>
        ) : (
          <p className="text-xs text-danger-text">{t("test_failure", { error: test.data.error || "" })}</p>
        )
      ) : null}
      {test.isError ? <p className="text-xs text-danger-text">{errorMessage(test.error, t("test_error_fallback"))}</p> : null}
    </div>
  )
}

function SchemaBrowser({ connectionId, label, onBack }: { connectionId: number; label: string; onBack: () => void }) {
  const { t } = useT("mysql_db_browser")
  const [browserTab, setBrowserTab] = useState<"browse" | "query" | "live">("browse")
  const [expandedDatabases, setExpandedDatabases] = useState<Set<string>>(new Set())
  const [selected, setSelected] = useState<{ database: string; table: string } | null>(null)
  const [tableTab, setTableTab] = useState<"content" | "structure" | "builder">("content")
  const databases = useQuery({
    queryKey: ["mysql_db_browser", "schema", connectionId, "databases"],
    queryFn: () => fetchMysqlDatabases(connectionId)
  })

  function toggleDatabase(name: string) {
    setExpandedDatabases((previous) => {
      const next = new Set(previous)
      if (next.has(name)) {
        next.delete(name)
      } else {
        next.add(name)
      }
      return next
    })
  }

  function selectTable(database: string, table: string) {
    setSelected({ database, table })
    setTableTab("content")
  }

  return (
    <section className="flex h-full min-h-0 flex-col gap-4">
      <div className="flex shrink-0 flex-wrap items-center justify-between gap-2">
        <div>
          <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("browse_heading", { label })}</h1>
          <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{t("browse_description")}</p>
        </div>
        <button
          className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800"
          onClick={onBack}
          type="button"
        >
          {t("back_to_connections")}
        </button>
      </div>

      <div className="flex shrink-0 gap-1 border-b border-gray-200 dark:border-gray-800" role="tablist">
        <TabButton active={browserTab === "browse"} onClick={() => setBrowserTab("browse")}>{t("tab_browse")}</TabButton>
        <TabButton active={browserTab === "query"} onClick={() => setBrowserTab("query")}>{t("tab_query")}</TabButton>
        <TabButton active={browserTab === "live"} onClick={() => setBrowserTab("live")}>{t("tab_live")}</TabButton>
      </div>

      {browserTab === "browse" ? (
        <>
          {databases.isPending ? <Panel>{t("loading_databases")}</Panel> : null}
          {databases.isError ? <Panel tone="error">{errorMessage(databases.error, t("error_loading_databases"))}</Panel> : null}

          {databases.isSuccess ? (
            <div className="grid min-h-0 flex-1 gap-4 lg:grid-cols-[280px_1fr]">
              <nav
                aria-label={t("aria_schema_tree")}
                className="h-full min-h-0 overflow-y-auto rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950"
              >
                <ul className="divide-y divide-gray-100 dark:divide-gray-900 text-sm">
                  {databases.data.databases.map((database) => (
                    <DatabaseNode
                      connectionId={connectionId}
                      database={database}
                      expanded={expandedDatabases.has(database.name)}
                      key={database.name}
                      onSelectTable={(table) => selectTable(database.name, table)}
                      onToggle={() => toggleDatabase(database.name)}
                      selectedTable={selected?.database === database.name ? selected.table : null}
                    />
                  ))}
                </ul>
              </nav>

              <div className="flex h-full min-h-0 min-w-0 flex-col overflow-hidden rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950">
                {selected ? (
                  <div className="flex h-full min-h-0 flex-col">
                    <div className="flex shrink-0 gap-1 border-b border-gray-200 dark:border-gray-800 px-2" role="tablist">
                      <TabButton active={tableTab === "content"} onClick={() => setTableTab("content")}>{t("tab_content")}</TabButton>
                      <TabButton active={tableTab === "structure"} onClick={() => setTableTab("structure")}>{t("tab_structure")}</TabButton>
                      <TabButton active={tableTab === "builder"} onClick={() => setTableTab("builder")}>{t("tab_builder")}</TabButton>
                    </div>
                    <div className="min-h-0 flex-1 overflow-y-auto">
                      {tableTab === "content" ? (
                        <MysqlContentTab connectionId={connectionId} database={selected.database} table={selected.table} />
                      ) : tableTab === "structure" ? (
                        <TableDetail connectionId={connectionId} database={selected.database} table={selected.table} />
                      ) : (
                        <MysqlQueryBuilderTab connectionId={connectionId} database={selected.database} table={selected.table} />
                      )}
                    </div>
                  </div>
                ) : (
                  <p className="p-4 text-sm text-gray-500 dark:text-gray-400">{t("select_table_hint")}</p>
                )}
              </div>
            </div>
          ) : null}
        </>
      ) : null}

      {browserTab === "query" ? (
        <div className="flex h-full min-h-0 flex-col overflow-y-auto rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950 p-4">
          <MysqlQueryTab connectionId={connectionId} />
        </div>
      ) : null}

      {browserTab === "live" ? (
        <div className="flex h-full min-h-0 flex-col overflow-y-auto rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950 p-4">
          <MysqlLiveTab connectionId={connectionId} />
        </div>
      ) : null}
    </section>
  )
}

function TabButton({ active, children, onClick }: { active: boolean; children: ReactNode; onClick: () => void }) {
  return (
    <button
      aria-selected={active}
      className={`border-b-2 px-3 py-2 text-sm font-medium ${
        active
          ? "border-brand text-brand dark:text-brand-emphasis"
          : "border-transparent text-gray-500 hover:text-gray-900 dark:text-gray-400 dark:hover:text-gray-100"
      }`}
      onClick={onClick}
      role="tab"
      type="button"
    >
      {children}
    </button>
  )
}

function DatabaseNode({
  connectionId,
  database,
  expanded,
  onSelectTable,
  onToggle,
  selectedTable
}: {
  connectionId: number
  database: { name: string; system_schema: boolean }
  expanded: boolean
  onSelectTable: (table: string) => void
  onToggle: () => void
  selectedTable: string | null
}) {
  const { t } = useT("mysql_db_browser")
  const tables = useQuery({
    queryKey: ["mysql_db_browser", "schema", connectionId, "tables", database.name],
    queryFn: () => fetchMysqlTables(connectionId, database.name),
    enabled: expanded
  })

  return (
    <li>
      <button
        aria-expanded={expanded}
        className="flex w-full items-center justify-between gap-2 px-3 py-2 text-left hover:bg-gray-50 dark:hover:bg-gray-900"
        onClick={onToggle}
        type="button"
      >
        <span className="flex min-w-0 items-center gap-2">
          <span aria-hidden className="text-gray-400 dark:text-gray-600">{expanded ? "▾" : "▸"}</span>
          <span className="truncate font-medium text-gray-900 dark:text-gray-100">{database.name}</span>
        </span>
        {database.system_schema ? (
          <span className="shrink-0 rounded bg-gray-100 dark:bg-gray-800 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-gray-500 dark:text-gray-400">
            {t("system_schema_badge")}
          </span>
        ) : null}
      </button>

      {expanded ? (
        <div className="pb-1 pl-5 pr-2">
          {tables.isPending ? <p className="py-1 text-xs text-gray-500 dark:text-gray-400">{t("loading_tables")}</p> : null}
          {tables.isError ? (
            <p className="py-1 text-xs text-red-700 dark:text-red-300">{errorMessage(tables.error, t("error_loading_tables"))}</p>
          ) : null}
          {tables.isSuccess && !tables.data.available ? (
            <p className="py-1 text-xs text-red-700 dark:text-red-300">{tables.data.error.hint || tables.data.error.message}</p>
          ) : null}
          {tables.isSuccess && tables.data.available ? (
            tables.data.tables.length === 0 ? (
              <p className="py-1 text-xs text-gray-500 dark:text-gray-400">{t("no_tables")}</p>
            ) : (
              <>
                <ul className="space-y-0.5">
                  {tables.data.tables.map((table) => (
                    <li key={table.name}>
                      <button
                        className={`block w-full truncate rounded px-2 py-1 text-left text-xs ${
                          selectedTable === table.name
                            ? "bg-brand/10 font-medium text-brand dark:text-brand-emphasis"
                            : "text-gray-600 dark:text-gray-400 hover:bg-gray-50 dark:hover:bg-gray-900"
                        }`}
                        onClick={() => onSelectTable(table.name)}
                        type="button"
                      >
                        {table.name}
                      </button>
                    </li>
                  ))}
                </ul>
                {tables.data.truncated ? (
                  <p className="py-1 text-xs text-amber-700 dark:text-amber-400">{t("tables_truncated")}</p>
                ) : null}
              </>
            )
          ) : null}
        </div>
      ) : null}
    </li>
  )
}

function TableDetail({ connectionId, database, table }: { connectionId: number; database: string; table: string }) {
  const { t } = useT("mysql_db_browser")
  const detail = useQuery({
    queryKey: ["mysql_db_browser", "schema", connectionId, "table", database, table],
    queryFn: () => fetchMysqlTableDetail(connectionId, database, table)
  })

  if (detail.isPending) {
    return <p className="p-4 text-sm text-gray-500 dark:text-gray-400">{t("loading_table")}</p>
  }

  if (detail.isError) {
    return <p className="p-4 text-sm text-red-700 dark:text-red-300">{errorMessage(detail.error, t("error_loading_table"))}</p>
  }

  const data: MysqlTableDetailResponse = detail.data

  return (
    <div className="space-y-4 p-4">
      <header>
        <h3 className="font-mono text-sm font-semibold text-gray-900 dark:text-gray-100">
          {data.database}.{data.table}
        </h3>
        {data.info.available ? (
          <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
            {t("table_meta", {
              engine: data.info.engine || "-",
              rows: formatApproxCount(data.info.approximate_row_count),
              size: formatBytes((data.info.data_length_bytes || 0) + (data.info.index_length_bytes || 0))
            })}
          </p>
        ) : (
          <p className="mt-1 text-xs text-red-700 dark:text-red-300">{data.info.error.hint || data.info.error.message}</p>
        )}
      </header>

      <SchemaSection heading={t("columns_heading")} section={data.columns}>
        {(columns: MysqlColumn[]) => (
          <DataTable.Root className="text-xs" density="compact">
            <DataTable.Header>
              <DataTable.Row>
                <DataTable.HeadCell>{t("col_column_name")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_column_type")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_column_nullable")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_column_key")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_column_default")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_column_extra")}</DataTable.HeadCell>
              </DataTable.Row>
            </DataTable.Header>
            <DataTable.Body>
                {columns.map((column) => (
                  <DataTable.Row key={column.name}>
                    <DataTable.Cell className="font-mono text-gray-900 dark:text-gray-100">{column.name}</DataTable.Cell>
                    <DataTable.Cell className="text-gray-600 dark:text-gray-400">{column.column_type}</DataTable.Cell>
                    <DataTable.Cell className="text-gray-600 dark:text-gray-400">{column.nullable ? t("yes") : t("no")}</DataTable.Cell>
                    <DataTable.Cell className="text-gray-600 dark:text-gray-400">{column.key || "-"}</DataTable.Cell>
                    <DataTable.Cell className="max-w-[160px] truncate text-gray-600 dark:text-gray-400">{column.default ?? "-"}</DataTable.Cell>
                    <DataTable.Cell className="text-gray-600 dark:text-gray-400">{column.extra || "-"}</DataTable.Cell>
                  </DataTable.Row>
                ))}
            </DataTable.Body>
          </DataTable.Root>
        )}
      </SchemaSection>

      <SchemaSection heading={t("indexes_heading")} section={data.indexes}>
        {(indexes: MysqlIndex[]) =>
          indexes.length === 0 ? (
            <p className="text-xs text-gray-500 dark:text-gray-400">{t("no_indexes")}</p>
          ) : (
            <ul className="space-y-1 text-xs">
              {indexes.map((index) => (
                <li className="text-gray-700 dark:text-gray-300" key={index.name}>
                  <span className="font-mono font-medium">{index.name}</span>{" "}
                  <span className="text-gray-500 dark:text-gray-400">
                    ({index.columns.join(", ")}){index.unique ? ` · ${t("unique_badge")}` : ""}
                  </span>
                </li>
              ))}
            </ul>
          )
        }
      </SchemaSection>

      <SchemaSection heading={t("foreign_keys_heading")} section={data.foreign_keys}>
        {(foreignKeys: MysqlForeignKey[]) =>
          foreignKeys.length === 0 ? (
            <p className="text-xs text-gray-500 dark:text-gray-400">{t("no_foreign_keys")}</p>
          ) : (
            <ul className="space-y-1 text-xs">
              {foreignKeys.map((fk) => (
                <li className="font-mono text-gray-700 dark:text-gray-300" key={fk.constraint_name}>
                  {fk.from_table}.{fk.from_column} <span aria-hidden="true">→</span> {fk.to_table}.{fk.to_column}
                </li>
              ))}
            </ul>
          )
        }
      </SchemaSection>
    </div>
  )
}

function SchemaSection<TRow>({
  children,
  heading,
  section
}: {
  children: (rows: TRow[]) => ReactNode
  heading: string
  section: MysqlSection<TRow>
}) {
  const { t } = useT("mysql_db_browser")

  return (
    <div>
      <h4 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{heading}</h4>
      <div className="mt-2">
        {section.available ? (
          <>
            {children(section.rows)}
            {section.truncated ? <p className="mt-1 text-xs text-amber-700 dark:text-amber-400">{t("rows_truncated")}</p> : null}
          </>
        ) : (
          <p className="text-xs text-red-700 dark:text-red-300">{section.error.hint || section.error.message}</p>
        )}
      </div>
    </div>
  )
}

function formatApproxCount(value: number | null) {
  return value === null ? "-" : value.toLocaleString()
}

function formatBytes(bytes: number) {
  if (!bytes) return "0 B"
  const units = [ "B", "KB", "MB", "GB", "TB" ]
  const exponent = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1)
  const value = bytes / 1024 ** exponent
  return `${value.toFixed(exponent === 0 ? 0 : 1)} ${units[exponent]}`
}

function StatusBadge({ children, tone }: { children: ReactNode; tone: "success" | "neutral" | "warning" }) {
  const classes = tone === "success"
    ? "bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"
    : tone === "warning"
      ? "bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-300"
      : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400"
  return <span className={`inline-flex items-center rounded px-2 py-0.5 text-xs font-medium ${classes}`}>{children}</span>
}

function useMediaQuery(query: string, defaultMatches: boolean) {
  const [matches, setMatches] = useState(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return defaultMatches

    return window.matchMedia(query).matches
  })

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return

    const media = window.matchMedia(query)
    const updateMatches = () => setMatches(media.matches)
    updateMatches()

    if (typeof media.addEventListener === "function") {
      media.addEventListener("change", updateMatches)
      return () => media.removeEventListener("change", updateMatches)
    }

    media.addListener(updateMatches)
    return () => media.removeListener(updateMatches)
  }, [query])

  return matches
}

function Panel({ children, tone = "neutral" }: { children: ReactNode; tone?: "neutral" | "error" | "success" }) {
  const classes = tone === "error"
    ? "border-red-200 bg-red-50 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200"
    : tone === "success"
      ? "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-200"
      : "border-gray-200 bg-white text-gray-700 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-200"
  return <div className={`rounded border px-4 py-3 text-sm ${classes}`}>{children}</div>
}

export default MysqlConnections
