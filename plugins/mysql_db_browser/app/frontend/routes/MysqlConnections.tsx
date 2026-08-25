import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState, type FormEvent, type ReactNode } from "react"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { NoticeToast } from "@app/components/NoticeToast"
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

const queryKey = ["mysql_db_browser", "connections"] as const

const EMPTY_FORM: MysqlConnectionInput = {
  label: "",
  host: "",
  port: 3306,
  username: "",
  default_database: "",
  agentic_access_enabled: false,
  password: ""
}

const INPUT_CLASSES = "mt-1 block w-full rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1.5 text-sm normal-case text-gray-700 dark:text-gray-300"

export function MysqlConnections() {
  const { t } = useT("mysql_db_browser")
  usePageTitle(t("heading"))
  const [notice, setNotice] = useState<string | null>(null)
  const connections = useQuery({
    queryKey,
    queryFn: fetchMysqlConnections
  })

  return (
    <main aria-label={t("aria_page")} className="mx-auto max-w-5xl space-y-6 p-6">
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
          <ConnectionsTable connections={connections.data.mysql_connections} onNotice={setNotice} />
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
        <div className="flex flex-wrap items-center gap-3">
          <button
            className="rounded bg-terracotta-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-terracotta-500 disabled:cursor-not-allowed disabled:opacity-50"
            disabled={create.isPending}
            type="submit"
          >
            {create.isPending ? t("creating") : t("create_button")}
          </button>
          <TestButton onTest={() => testDraftMysqlConnection(values)} />
        </div>
      </form>
      {create.isError ? <p className="mt-3 text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(create.error, t("create_error_fallback"))}</p> : null}
    </section>
  )
}

function ConnectionsTable({ connections, onNotice }: { connections: MysqlConnectionRow[]; onNotice: (message: string | null) => void }) {
  const { t } = useT("mysql_db_browser")
  const [editingId, setEditingId] = useState<number | null>(null)

  return (
    <section className="overflow-hidden rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950">
      <div className="overflow-x-auto">
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-800 text-sm">
          <thead className="bg-gray-50 dark:bg-gray-900 text-left text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <th className="px-4 py-2">{t("col_label")}</th>
              <th className="px-4 py-2">{t("col_host")}</th>
              <th className="px-4 py-2">{t("col_username")}</th>
              <th className="px-4 py-2">{t("col_default_database")}</th>
              <th className="px-4 py-2">{t("col_password")}</th>
              <th className="px-4 py-2">{t("col_agentic_access")}</th>
              <th className="px-4 py-2"><span className="sr-only">{t("col_actions")}</span></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-900">
            {connections.length === 0 ? (
              <tr><td className="px-4 py-6 text-center text-gray-500 dark:text-gray-400" colSpan={7}>{t("empty")}</td></tr>
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
                  onEdit={() => setEditingId(connection.id)}
                  onNotice={onNotice}
                />
              )
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}

function ConnectionRow({ connection, onEdit, onNotice }: { connection: MysqlConnectionRow; onEdit: () => void; onNotice: (message: string | null) => void }) {
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
    <tr>
      <td className="px-4 py-3 font-medium text-gray-900 dark:text-gray-100">{connection.label}</td>
      <td className="px-4 py-3 font-mono text-xs text-gray-700 dark:text-gray-300">{connection.host}:{connection.port}</td>
      <td className="px-4 py-3 text-gray-700 dark:text-gray-300">{connection.username}</td>
      <td className="px-4 py-3 text-gray-700 dark:text-gray-300">{connection.default_database || "-"}</td>
      <td className="px-4 py-3">
        <StatusBadge tone={connection.has_password ? "success" : "neutral"}>
          {connection.has_password ? t("has_password_yes") : t("has_password_no")}
        </StatusBadge>
      </td>
      <td className="px-4 py-3">
        <StatusBadge tone={connection.agentic_access_enabled ? "success" : "neutral"}>
          {connection.agentic_access_enabled ? t("agentic_enabled") : t("agentic_disabled")}
        </StatusBadge>
      </td>
      <td className="px-4 py-3">
        <div className="flex flex-wrap items-start justify-end gap-2">
          <TestButton onTest={() => testMysqlConnection(connection.id)} />
          <button
            className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800"
            onClick={onEdit}
            type="button"
          >
            {t("edit_button")}
          </button>
          <button
            className="rounded border border-red-300 dark:border-red-900 px-3 py-1.5 text-sm font-medium text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950 disabled:cursor-not-allowed disabled:opacity-50"
            disabled={destroy.isPending}
            onClick={() => {
              if (window.confirm(t("confirm_delete", { label: connection.label }))) {
                onNotice(null)
                destroy.mutate()
              }
            }}
            type="button"
          >
            {destroy.isPending ? t("deleting") : t("delete_button")}
          </button>
        </div>
        {destroy.isError ? <p className="mt-2 text-right text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(destroy.error, t("delete_error_fallback"))}</p> : null}
      </td>
    </tr>
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
  const { t } = useT("mysql_db_browser")
  const queryClient = useQueryClient()
  const [values, setValues] = useState<MysqlConnectionInput>({
    label: connection.label,
    host: connection.host,
    port: connection.port,
    username: connection.username,
    default_database: connection.default_database || "",
    agentic_access_enabled: connection.agentic_access_enabled,
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
    <tr>
      <td className="px-4 py-4" colSpan={7}>
        <form className="space-y-3" onSubmit={submit}>
          <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("edit_heading")}</h3>
          <ConnectionFieldsGrid
            idPrefix={`edit-connection-${connection.id}`}
            onChange={setValues}
            passwordHint={t("field_password_hint_edit")}
            values={values}
          />
          <div className="flex flex-wrap items-center gap-3">
            <button
              className="rounded bg-gray-900 dark:bg-gray-100 px-3 py-1.5 text-sm font-medium text-white dark:text-gray-900 hover:bg-gray-800 dark:hover:bg-white disabled:cursor-not-allowed disabled:opacity-50"
              disabled={update.isPending}
              type="submit"
            >
              {update.isPending ? t("saving") : t("save_button")}
            </button>
            <button
              className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800"
              onClick={onCancel}
              type="button"
            >
              {t("cancel_button")}
            </button>
            <TestButton onTest={() => testMysqlConnection(connection.id, values.password || undefined)} />
          </div>
          {update.isError ? <p className="text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(update.error, t("update_error_fallback"))}</p> : null}
        </form>
      </td>
    </tr>
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
      <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor={`${idPrefix}-label`}>
        {t("field_label")}
        <input
          className={INPUT_CLASSES}
          id={`${idPrefix}-label`}
          onChange={(event) => set("label", event.target.value)}
          required
          type="text"
          value={values.label}
        />
      </label>
      <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor={`${idPrefix}-host`}>
        {t("field_host")}
        <input
          className={INPUT_CLASSES}
          id={`${idPrefix}-host`}
          onChange={(event) => set("host", event.target.value)}
          required
          type="text"
          value={values.host}
        />
      </label>
      <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor={`${idPrefix}-port`}>
        {t("field_port")}
        <input
          className={INPUT_CLASSES}
          id={`${idPrefix}-port`}
          max={65535}
          min={1}
          onChange={(event) => set("port", Number(event.target.value))}
          required
          type="number"
          value={values.port}
        />
      </label>
      <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor={`${idPrefix}-username`}>
        {t("field_username")}
        <input
          className={INPUT_CLASSES}
          id={`${idPrefix}-username`}
          onChange={(event) => set("username", event.target.value)}
          required
          type="text"
          value={values.username}
        />
      </label>
      <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor={`${idPrefix}-password`}>
        {t("field_password")}
        <input
          autoComplete="new-password"
          className={INPUT_CLASSES}
          id={`${idPrefix}-password`}
          onChange={(event) => set("password", event.target.value)}
          required={passwordRequired}
          type="password"
          value={values.password ?? ""}
        />
        {passwordHint ? <span className="mt-1 block text-xs normal-case text-gray-500 dark:text-gray-400">{passwordHint}</span> : null}
      </label>
      <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor={`${idPrefix}-default-database`}>
        {t("field_default_database")} <span className="normal-case text-gray-400 dark:text-gray-500">{t("field_default_database_optional")}</span>
        <input
          className={INPUT_CLASSES}
          id={`${idPrefix}-default-database`}
          onChange={(event) => set("default_database", event.target.value)}
          type="text"
          value={values.default_database}
        />
      </label>
      <label className="flex items-start gap-2 text-sm normal-case text-gray-700 dark:text-gray-300 sm:col-span-2 lg:col-span-3" htmlFor={`${idPrefix}-agentic-access`}>
        <input
          checked={values.agentic_access_enabled}
          className="mt-0.5 rounded border-gray-300 dark:border-gray-600"
          id={`${idPrefix}-agentic-access`}
          onChange={(event) => set("agentic_access_enabled", event.target.checked)}
          type="checkbox"
        />
        <span>
          {t("field_agentic_access")}
          <span className="block text-xs text-gray-500 dark:text-gray-400">{t("field_agentic_access_hint")}</span>
        </span>
      </label>
    </div>
  )
}

function TestButton({ onTest }: { onTest: () => Promise<MysqlConnectionTestResult> }) {
  const { t } = useT("mysql_db_browser")
  const test = useMutation({ mutationFn: onTest })

  return (
    <div className="flex flex-col items-start gap-1">
      <button
        className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:cursor-not-allowed disabled:opacity-50"
        disabled={test.isPending}
        onClick={() => test.mutate()}
        type="button"
      >
        {test.isPending ? t("testing") : t("test_button")}
      </button>
      {test.isSuccess ? (
        test.data.success ? (
          <p className="text-xs text-emerald-700 dark:text-emerald-300">{t("test_success")}</p>
        ) : (
          <p className="text-xs text-red-700 dark:text-red-300">{t("test_failure", { error: test.data.error || "" })}</p>
        )
      ) : null}
      {test.isError ? <p className="text-xs text-red-700 dark:text-red-300">{errorMessage(test.error, t("test_error_fallback"))}</p> : null}
    </div>
  )
}

function StatusBadge({ children, tone }: { children: ReactNode; tone: "success" | "neutral" }) {
  const classes = tone === "success"
    ? "bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"
    : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400"
  return <span className={`inline-flex items-center rounded px-2 py-0.5 text-xs font-medium ${classes}`}>{children}</span>
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
