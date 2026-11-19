import { useQuery } from "@tanstack/react-query"
import { DataTable, Notice, Page, Section, Text } from "@app/components/ui"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { formatBytes } from "@app/lib/format"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { fetchAdminLocalBackups } from "../api/adminLocalBackups"

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
      </Page.Header>
      {query.isPending ? <Notice>{t("loading")}</Notice> : null}
      {query.isError ? <Notice tone="danger">{t("load_error")}</Notice> : null}
      {query.data ? <Inventory payload={query.data} /> : null}
    </Page.Root>
  )
}

export default AdminLocalBackups

function Inventory({ payload }: { payload: Awaited<ReturnType<typeof fetchAdminLocalBackups>> }) {
  const { t } = useT("local_backups")
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
                </DataTable.Row>
              ))}
            </DataTable.Body>
          </DataTable.Root>
        )}
      </Section.Root>
    </>
  )
}
