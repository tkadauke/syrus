import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Button, buttonClasses, DataTable, Notice, Page, Section, Text } from "@app/components/ui"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { formatBytes } from "@app/lib/format"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import {
  createLocalBackup,
  deleteLocalBackup,
  fetchAdminLocalBackups,
  localBackupDownloadUrl,
  pinLocalBackup,
  unpinLocalBackup,
  validateLocalBackup
} from "../api/adminLocalBackups"

export function AdminLocalBackups() {
  const { t } = useT("local_backups")
  usePageTitle(t("page_title"))
  const query = useQuery({ queryKey: ["admin", "local_backups"], queryFn: fetchAdminLocalBackups })

  return (
    <Page.Root aria-label={t("aria_main")} gutter="responsive" size="wide">
      <Page.Header className="border-b border-border pb-4">
        <Page.HeadingGroup>
          <Page.Title>{t("heading")}</Page.Title>
        </Page.HeadingGroup>
        <Page.Description>{t("description")}</Page.Description>
        <Button onClick={() => createLocalBackup().then(() => query.refetch())}>{t("create")}</Button>
      </Page.Header>
      {query.isPending ? <Notice>{t("loading")}</Notice> : null}
      {query.isError ? <Notice tone="danger">{t("load_error")}</Notice> : null}
      {query.data ? <Inventory payload={query.data} /> : null}
      <Section.Root>
        <Section.Header>
          <Section.Title>{t("recovery_title")}</Section.Title>
        </Section.Header>
        <Text>{t("recovery_normal")}</Text>
        <Text tone="muted">{t("recovery_bootstrap")}</Text>
        <Notice tone="warning">{t("recovery_execution_warning")}</Notice>
      </Section.Root>
    </Page.Root>
  )
}

export default AdminLocalBackups

function Inventory({ payload }: { payload: Awaited<ReturnType<typeof fetchAdminLocalBackups>> }) {
  const { t } = useT("local_backups")
  const queryClient = useQueryClient()
  const mutation = useMutation({
    mutationFn: ({ action, id }: { action: "validate" | "pin" | "unpin" | "delete"; id: string }) => {
      if (action === "validate") return validateLocalBackup(id)
      if (action === "pin") return pinLocalBackup(id)
      if (action === "unpin") return unpinLocalBackup(id)
      return deleteLocalBackup(id)
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["admin", "local_backups"] })
  })
  return (
    <>
      {!payload.root.configured ? (
        <Notice tone="warning">{payload.root.error || t("not_configured")}</Notice>
      ) : (
        <Section.Root>
          <Section.Header>
            <Section.Title>{t("storage")}</Section.Title>
          </Section.Header>
          <Text>{payload.root.path}</Text>
          {payload.root.available_bytes != null ? <Text tone="muted">{t("available", { size: formatBytes(payload.root.available_bytes) })}</Text> : null}
        </Section.Root>
      )}
      {payload.scan.invalid.length ? <Notice tone="warning">{t("invalid", { count: payload.scan.invalid.length })}</Notice> : null}
      <Section.Root>
        <Section.Header>
          <Section.Title>{t("inventory")}</Section.Title>
        </Section.Header>
        {payload.backups.length === 0 ? (
          <Text tone="muted">{t("empty")}</Text>
        ) : (
          <DataTable.Root>
            <DataTable.Header>
              <DataTable.Row>
                <DataTable.HeadCell>{t("created")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("source")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("database")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("blobs")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("size")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("validation")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("actions")}</DataTable.HeadCell>
              </DataTable.Row>
            </DataTable.Header>
            <DataTable.Body>
              {payload.backups.map((backup) => (
                <DataTable.Row key={backup.uuid}>
                  <DataTable.Cell>
                    <RelativeTimestamp value={backup.completed_at} />
                  </DataTable.Cell>
                  <DataTable.Cell>{backup.source_application_version || "—"}</DataTable.Cell>
                  <DataTable.Cell>{backup.database_adapter || "—"}</DataTable.Cell>
                  <DataTable.Cell>{backup.blob_count.toLocaleString()}</DataTable.Cell>
                  <DataTable.Cell>{formatBytes(backup.stored_bytes)}</DataTable.Cell>
                  <DataTable.Cell>{backup.verification_state || "—"}</DataTable.Cell>
                  <DataTable.Cell>
                    <div className="flex gap-2">
                      <Button size="sm" onClick={() => mutation.mutate({ action: "validate", id: backup.uuid })}>
                        {t("validate")}
                      </Button>
                      <Button size="sm" onClick={() => mutation.mutate({ action: backup.pinned ? "unpin" : "pin", id: backup.uuid })}>
                        {t(backup.pinned ? "unpin" : "pin")}
                      </Button>
                      <Button size="sm" onClick={() => window.confirm(t("delete_confirm")) && mutation.mutate({ action: "delete", id: backup.uuid })}>
                        {t("delete")}
                      </Button>
                      <a className={buttonClasses("secondary", "sm")} href={localBackupDownloadUrl(backup.uuid)}>
                        {t("download")}
                      </a>
                    </div>
                  </DataTable.Cell>
                </DataTable.Row>
              ))}
            </DataTable.Body>
          </DataTable.Root>
        )}
      </Section.Root>
    </>
  )
}
