import type { FilterLinkBuilder } from "../components/FilterBar"

type FilterLinkUpdates = Parameters<FilterLinkBuilder>[2]

export function adminSmartFolderFilterLinkBuilder(activeUserFolderId: number | null | undefined): FilterLinkBuilder {
  return (path: string, search: string, updates: FilterLinkUpdates) => {
    const nextUpdates = { ...updates }
    if (activeUserFolderId != null && nextUpdates.smart_folder_id === null) {
      nextUpdates.smart_folder_id = activeUserFolderId
    }

    return linkFromSearch(path, search, nextUpdates)
  }
}

function linkFromSearch(path: string, search: string, updates: FilterLinkUpdates) {
  const params = new URLSearchParams(search)
  for (const [key, value] of Object.entries(updates)) {
    if (value == null || String(value).length === 0) {
      params.delete(key)
    } else {
      params.set(key, String(value))
    }
  }

  const query = params.toString()
  return query ? `${path}?${query}` : path
}
