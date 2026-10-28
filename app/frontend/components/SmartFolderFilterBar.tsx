import type { AdminSmartFolder } from "../api/adminSmartFolders"
import { FilterBar, type FilterLinkBuilder } from "./FilterBar"
import { encodeFilterTree } from "./filterBar/helpers"

type SmartFolderIdentity = Pick<AdminSmartFolder, "id" | "kind">

export function smartFolderFilterLinkBuilder({
  activeSmartFolderId,
  buildLink,
  smartFolders
}: {
  activeSmartFolderId: number | null | undefined
  buildLink: FilterLinkBuilder
  smartFolders: SmartFolderIdentity[]
}): FilterLinkBuilder {
  const activeFolder = smartFolders.find((folder) => folder.id === activeSmartFolderId)

  return (path, search, updates) => {
    const nextUpdates = { ...updates }
    const changesFilter = Object.hasOwn(nextUpdates, "q")

    if (activeFolder && changesFilter && nextUpdates.q == null) {
      nextUpdates.q = encodeFilterTree({ and: [] })
    }

    if (activeFolder?.kind === "user_defined") {
      if (nextUpdates.smart_folder_id == null) nextUpdates.smart_folder_id = activeFolder.id
    } else if (changesFilter) {
      // Once a built-in preset is changed, its identity no longer describes
      // the effective filter. Keep q (including an encoded empty tree), but
      // stop highlighting the original folder in navigation.
      nextUpdates.smart_folder_id = null
    }

    return buildLink(path, search, nextUpdates)
  }
}

export function SmartFolderFilterBar({
  activeSmartFolderId,
  buildLink,
  smartFolders,
  ...filterBarProps
}: Omit<React.ComponentProps<typeof FilterBar>, "buildLink"> & {
  activeSmartFolderId: number | null | undefined
  buildLink: FilterLinkBuilder
  smartFolders: SmartFolderIdentity[]
}) {
  return <FilterBar {...filterBarProps} buildLink={smartFolderFilterLinkBuilder({ activeSmartFolderId, buildLink, smartFolders })} />
}
