import { useState } from "react"
import { Input } from "@app/components/Input"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"

// Shared table fundamentals for the cluster browser: a client-side text
// filter, a visible capped-results notice, and a case-insensitive matcher.
// Every tab renders these same controls so search, truncation, headers, and
// empty states behave identically across resource kinds.
export function matchesSearch(query: string, ...haystacks: Array<string | number | null | undefined>): boolean {
  const needle = query.trim().toLowerCase()
  if (!needle) return true

  return haystacks.some((haystack) => {
    if (haystack === null || haystack === undefined) return false
    return String(haystack).toLowerCase().includes(needle)
  })
}

export function useTableSearch() {
  const [query, setQuery] = useState("")
  return { query, setQuery }
}

export function TableSearch({ query, onChange }: { query: string; onChange: (query: string) => void }) {
  const { t } = useT("k8s_cluster")

  return (
    <Input
      aria-label={t("search_label")}
      fullWidth={false}
      onChange={(event) => onChange(event.target.value)}
      placeholder={t("search_placeholder")}
      type="search"
      value={query}
    />
  )
}

export function TruncatedNotice() {
  const { t } = useT("k8s_cluster")

  return <PanelMessage tone="warning">{t("truncated_notice")}</PanelMessage>
}

export function SearchNoMatches() {
  const { t } = useT("k8s_cluster")

  return <PanelMessage>{t("search_no_matches")}</PanelMessage>
}
