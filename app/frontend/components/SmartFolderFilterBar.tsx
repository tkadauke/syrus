import type { AdminSmartFolder } from "../api/adminSmartFolders"
import { FilterBar, type FilterLinkBuilder } from "./FilterBar"
import { encodeFilterTree } from "./filterBar/helpers"
import type { FilterNode, FilterSchemaField, FilterTree } from "./filterBar/types"

type SmartFolderIdentity = Pick<AdminSmartFolder, "id" | "kind">

export function smartFolderFilterLinkBuilder({
  activeSmartFolderId,
  buildLink,
  filter,
  filterSchema,
  smartFolders
}: {
  activeSmartFolderId: number | null | undefined
  buildLink: FilterLinkBuilder
  filter?: Record<string, unknown> | null
  filterSchema: FilterSchemaField[]
  smartFolders: SmartFolderIdentity[]
}): FilterLinkBuilder {
  const activeFolder = smartFolders.find((folder) => folder.id === activeSmartFolderId)
  const presetFields = new Set(filterSchema.filter((field) => field.bucket === "preset").map((field) => field.field))
  const activePresetChips = collectPresetChips(filter as FilterTree | null | undefined, presetFields)

  return (path, search, updates) => {
    const nextUpdates = { ...updates }
    const changesFilter = Object.hasOwn(nextUpdates, "q")

    if (activeFolder && changesFilter && nextUpdates.q == null) {
      nextUpdates.q = encodeFilterTree({ and: [] })
    }

    if (activeFolder?.kind === "user_defined") {
      if (nextUpdates.smart_folder_id == null) nextUpdates.smart_folder_id = activeFolder.id
    } else if (changesFilter && !preservesActivePreset(nextUpdates.q, activePresetChips)) {
      // Once a built-in preset is changed, its identity no longer describes
      // the effective filter. Keep q (including an encoded empty tree), but
      // stop highlighting the original folder in navigation.
      nextUpdates.smart_folder_id = null
    }

    return buildLink(path, search, nextUpdates)
  }
}

function preservesActivePreset(encodedFilter: unknown, activePresetChips: string[]) {
  if (activePresetChips.length === 0 || typeof encodedFilter !== "string") return false

  const nextTree = decodeFilterTree(encodedFilter)
  if (!nextTree) return false

  const activeFields = new Set(activePresetChips.map((signature) => signature.split("\u0000", 1)[0]))
  const nextPresetChips = new Set(collectPresetChips(nextTree, activeFields))
  return activePresetChips.every((signature) => nextPresetChips.has(signature))
}

function collectPresetChips(node: FilterNode | null | undefined, presetFields: Set<string>): string[] {
  if (!node || typeof node !== "object") return []
  if ("field" in node) return presetFields.has(node.field) ? [`${node.field}\u0000${JSON.stringify(node.value)}`] : []

  const children = [...(node.and ?? []), ...(node.or ?? []), ...(node.not ? [node.not] : [])]
  return children.flatMap((child) => collectPresetChips(child, presetFields))
}

function decodeFilterTree(encoded: string): FilterTree | null {
  try {
    const normalized = encoded.replace(/-/g, "+").replace(/_/g, "/")
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")
    return JSON.parse(decodeURIComponent(escape(atob(padded)))) as FilterTree
  } catch {
    return null
  }
}

export function SmartFolderFilterBar({
  activeSmartFolderId,
  buildLink,
  filter,
  filterSchema,
  smartFolders,
  ...filterBarProps
}: Omit<React.ComponentProps<typeof FilterBar>, "buildLink"> & {
  activeSmartFolderId: number | null | undefined
  buildLink: FilterLinkBuilder
  smartFolders: SmartFolderIdentity[]
}) {
  return (
    <FilterBar
      {...filterBarProps}
      buildLink={smartFolderFilterLinkBuilder({ activeSmartFolderId, buildLink, filter, filterSchema, smartFolders })}
      filter={filter}
      filterSchema={filterSchema}
    />
  )
}
