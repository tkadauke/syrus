import type { FilterLinkBuilder } from "../components/FilterBar"
import { smartFolderFilterLinkBuilder } from "../components/SmartFolderFilterBar"
import { linkFromSearch } from "../components/filterBar/helpers"

export function adminSmartFolderFilterLinkBuilder(activeUserFolderId: number | null | undefined): FilterLinkBuilder {
  return smartFolderFilterLinkBuilder({
    activeSmartFolderId: activeUserFolderId,
    buildLink: linkFromSearch,
    smartFolders: activeUserFolderId == null ? [] : [{ id: activeUserFolderId, kind: "user_defined" }]
  })
}
