import { Link } from "react-router-dom"
import type { AdminSmartFolder } from "../api/adminSmartFolders"

export function AdminSmartFolderNav({
  activeSmartFolderId,
  allLabel,
  allPath,
  ariaLabel,
  folders,
  heading,
  prefix,
  subjectType
}: {
  activeSmartFolderId: number | null
  allLabel: string
  allPath: string
  ariaLabel: string
  folders: AdminSmartFolder[]
  heading: string
  prefix: string
  subjectType: string
}) {
  const builtinFolders = folders.filter((folder) => folder.kind !== "user_defined")
  const primaryFolders = builtinFolders.filter((folder) => folder.visibility !== "on_demand")
  const moreFolders = builtinFolders.filter((folder) => folder.visibility === "on_demand")
  const savedFolders = folders.filter((folder) => folder.kind === "user_defined")

  return (
    <aside className="space-y-2">
      <h2 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{heading}</h2>
      <nav aria-label={ariaLabel} className="space-y-1">
        <Link className={folderClass(activeSmartFolderId == null)} to={withRoutePrefix(allPath, prefix)}>
          <span className="truncate">{allLabel}</span>
        </Link>
        {primaryFolders.map((folder) => <SmartFolderLink folder={folder} key={folder.id} prefix={prefix} />)}
        {moreFolders.length > 0 ? (
          <details className="space-y-1" open={moreFolders.some((folder) => folder.active) || undefined}>
            <summary className="cursor-pointer rounded px-2 py-1.5 text-sm font-medium text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800 dark:bg-gray-800">More</summary>
            <div className="space-y-1 pl-2">
              {moreFolders.map((folder) => <SmartFolderLink folder={folder} key={folder.id} prefix={prefix} />)}
            </div>
          </details>
        ) : null}
      </nav>
      <div className="space-y-1 pt-3">
        <div className="flex items-center justify-between gap-2 px-2">
          <h3 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">Saved</h3>
          <Link className="text-xs font-medium text-blue-700 dark:text-blue-300 hover:text-blue-900" to={`${prefix}/smart_folders?subject_type=${subjectType}`}>Manage</Link>
        </div>
        {savedFolders.length > 0 ? (
          <nav aria-label={`${ariaLabel} saved`} className="space-y-1">
            {savedFolders.map((folder) => <SmartFolderLink folder={folder} key={folder.id} prefix={prefix} />)}
          </nav>
        ) : (
          <p className="px-2 py-1.5 text-sm text-gray-400">No saved folders</p>
        )}
      </div>
    </aside>
  )
}

function SmartFolderLink({ folder, prefix }: { folder: AdminSmartFolder; prefix: string }) {
  return (
    <Link aria-label={`${folder.name} ${folder.count}`} className={folderClass(folder.active)} to={withRoutePrefix(folder.path, prefix)}>
      <span className="truncate">{folder.name}</span>
      <span className={`ml-auto inline-flex min-w-6 justify-center rounded-full px-1.5 py-0.5 text-xs ${folder.active ? "bg-blue-100 dark:bg-blue-950/60 text-blue-700 dark:text-blue-300" : "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300"}`}>{folder.count}</span>
    </Link>
  )
}

function folderClass(active: boolean) {
  return `flex items-center justify-between gap-2 rounded px-2 py-1.5 text-sm ${active ? "bg-blue-50 dark:bg-blue-950/40 font-medium text-blue-700 dark:text-blue-300" : "text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800 dark:bg-gray-800"}`
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}
