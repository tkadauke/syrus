import { useQuery } from "@tanstack/react-query"
import { DataTable, Notice, Page, Section, Text } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { formatBytes } from "@app/lib/format"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { fetchLocalBackups } from "../api/localBackups"

export default function AdminLocalBackups() {
  const { t } = useT("local_backups")
  usePageTitle(t("page_title"))
  const query = useQuery({ queryKey: ["admin", "local_backups"], queryFn: fetchLocalBackups })

  return (
    <Page.Root aria-label={t("aria_main")} gutter="responsive" size="wide">
      <Page.Header className="border-b border-border pb-4">
        <Page.HeadingGroup><Text as="p" muted variant="label">{t("admin:section_label")}</Text><Page.Title>{t("heading")}</Page.Title></Page.HeadingGroup>
        <Page.Description>{t("description")}</Page.Description>
      </Page.Header>
      {query.isPending ? <Notice>{t("loading")}</Notice> : null}
      {query.isError ? <Notice tone="danger">{t("load_error")}</Notice> : null}
      {query.data && !query.data.configured ? <Notice tone="warning">{query.data.error || t("not_configured")}</Notice> : null}
      {query.data?.configured ? (
        <>
          <Text muted>{t("root", { root: query.data.root })}</Text>
          <Section.Root>
            <Section.Header><Section.Title>{t("inventory")}</Section.Title></Section.Header>
            {query.data.backups.length === 0 ? <Notice>{t("empty")}</Notice> : (
              <DataTable.Root>
                <DataTable.Header><DataTable.Row><DataTable.HeadCell>{t("backup")}</DataTable.HeadCell><DataTable.HeadCell>{t("completed")}</DataTable.HeadCell><DataTable.HeadCell>{t("database")}</DataTable.HeadCell><DataTable.HeadCell>{t("size")}</DataTable.HeadCell><DataTable.HeadCell>{t("blobs")}</DataTable.HeadCell><DataTable.HeadCell>{t("verification")}</DataTable.HeadCell></DataTable.Row></DataTable.Header>
                <DataTable.Body>{query.data.backups.map((backup) => <DataTable.Row key={backup.uuid}><DataTable.Cell><code>{backup.uuid}</code></DataTable.Cell><DataTable.Cell><RelativeTimestamp value={backup.completed_at} /></DataTable.Cell><DataTable.Cell>{backup.database_adapter || "—"}</DataTable.Cell><DataTable.Cell>{formatBytes(backup.stored_bytes)}</DataTable.Cell><DataTable.Cell>{backup.blob_count}</DataTable.Cell><DataTable.Cell>{backup.verification_state}</DataTable.Cell></DataTable.Row>)}</DataTable.Body>
              </DataTable.Root>
            )}
          </Section.Root>
          {query.data.invalid_artifacts.length > 0 ? <Notice tone="warning">{t("invalid", { count: query.data.invalid_artifacts.length })}</Notice> : null}
        </>
      ) : null}
    </Page.Root>
  )
}
