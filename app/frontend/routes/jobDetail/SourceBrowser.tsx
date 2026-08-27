import { keepPreviousData, useQuery } from "@tanstack/react-query"
import type { Dispatch, ReactNode, SetStateAction } from "react"
import { useEffect, useMemo, useState } from "react"
import { Button } from "../../components/Button"
import { useT } from "../../hooks/useT"
import { highlightCode } from "../../lib/syntaxHighlight"
import { fetchJobSource, fetchJobSourceDiff, fetchWorkflowCoverageHitMap, type CoverageArtifact, type JobSourceDiffPayload, type JobSourcePayload } from "../../api/jobs"
import { errorMessage } from "../../lib/errorMessage"
import { formatBytes } from "../../lib/format"
import type { LineAnnotation } from "./diffRendering"
import { refOptionsFor, sourceDiffSearch, sourceSearch } from "./sourceRefs"
import { AgentDiff, PanelMessage } from "./components"
import type { SourceTreeNode } from "./sourceTree"
import { buildSourceTree, sourceLanguage } from "./sourceTree"


// Source-browser tab extracted from JobDetail.tsx: the SourceTab entry point and
// its subtree — the file-tree browser, coverage-annotated source view, the source
// shell, and the source-diff browser. Depends only on leaf modules and shared UI
// imports, so it carries no circular edge back to the route file. Unused header
// imports were pruned after the move.

export function SourceTab({ jobId, coverageInfo }: { jobId: string; coverageInfo: { workflowId: number; coverage: CoverageArtifact } | null }) {
  const [mode, setMode] = useState<"browse" | "diff">("browse")
  const [sourceRef, setSourceRef] = useState<string | null>(null)
  const [sourcePath, setSourcePath] = useState<string | null>(null)
  const [diffBaseRef, setDiffBaseRef] = useState<string | null>(null)
  const [diffHeadRef, setDiffHeadRef] = useState<string | null>(null)
  const [expandedPaths, setExpandedPaths] = useState<Set<string>>(() => new Set())
  const search = sourceSearch(sourceRef, sourcePath)
  const diffSearch = sourceDiffSearch(diffBaseRef, diffHeadRef)
  const source = useQuery({
    queryKey: ["jobs", jobId, "source", search],
    queryFn: () => fetchJobSource(jobId, search),
    placeholderData: keepPreviousData
  })
  const sourceDiff = useQuery({
    enabled: mode === "diff",
    queryKey: ["jobs", jobId, "source_diff", diffSearch],
    queryFn: () => fetchJobSourceDiff(jobId, diffSearch)
  })

  const { t } = useT("jobs")

  const diffAnnotations = coverageInfo?.coverage.diff_annotations ?? null
  const hitMapAttached = Boolean(coverageInfo?.coverage.hit_map_attached)
  const coverageWorkflowId = coverageInfo?.workflowId ?? null

  if (source.isPending) return <PanelMessage>{t("source_loading")}</PanelMessage>
  if (source.isError) return <PanelMessage tone="error">{errorMessage(source.error, t("source_error"))}</PanelMessage>

  if (mode === "diff") {
    if (sourceDiff.isPending) {
      return <SourceShell mode={mode} onModeChange={setMode} showDiffToggle={source.data.branch_commits.length > 0}><PanelMessage>{t("source_diff_loading")}</PanelMessage></SourceShell>
    }
    if (sourceDiff.isError) {
      return <SourceShell mode={mode} onModeChange={setMode} showDiffToggle={source.data.branch_commits.length > 0}><PanelMessage tone="error">{errorMessage(sourceDiff.error, t("source_diff_error"))}</PanelMessage></SourceShell>
    }

    return <SourceDiffBrowser diffAnnotations={diffAnnotations} mode={mode} onModeChange={setMode} onSelectBaseRef={setDiffBaseRef} onSelectHeadRef={setDiffHeadRef} payload={sourceDiff.data} showDiffToggle={source.data.branch_commits.length > 0} />
  }

  return <SourceBrowser coverageWorkflowId={coverageWorkflowId} expandedPaths={expandedPaths} hitMapAttached={hitMapAttached} mode={mode} onModeChange={setMode} payload={source.data} setExpandedPaths={setExpandedPaths} onSelectPath={(path) => {
    setSourceRef(source.data.selected_ref)
    setSourcePath(path)
  }} onSelectRef={(ref) => {
    setSourceRef(ref)
    setSourcePath(null)
  }} showDiffToggle={source.data.branch_commits.length > 0} />
}

function SourceBrowser({
  coverageWorkflowId,
  expandedPaths,
  hitMapAttached,
  mode,
  onModeChange,
  payload,
  setExpandedPaths,
  onSelectPath,
  onSelectRef,
  showDiffToggle
}: {
  coverageWorkflowId: number | null
  expandedPaths: Set<string>
  hitMapAttached: boolean
  mode: "browse" | "diff"
  onModeChange: (mode: "browse" | "diff") => void
  payload: JobSourcePayload
  setExpandedPaths: Dispatch<SetStateAction<Set<string>>>
  onSelectPath: (path: string) => void
  onSelectRef: (ref: string) => void
  showDiffToggle: boolean
}) {
  const { t } = useT("jobs")
  const visibleItems = useMemo(() => payload.tree_items.slice(0, 2000), [payload.tree_items])
  const tree = useMemo(() => buildSourceTree(visibleItems), [visibleItems])
  const refOptions = refOptionsFor(payload, [payload.selected_ref])
  const fileLanguage = payload.file ? sourceLanguage(payload.file.language) : null
  const selectedFilePath = payload.file?.path ?? null

  const hitMap = useQuery({
    enabled: hitMapAttached && coverageWorkflowId != null && selectedFilePath != null,
    queryKey: ["workflow_coverage_hit_map", coverageWorkflowId, selectedFilePath],
    queryFn: () => fetchWorkflowCoverageHitMap(coverageWorkflowId!, selectedFilePath!),
    staleTime: 5 * 60 * 1000
  })

  if (payload.source_error) return <PanelMessage tone="error">{payload.source_error}</PanelMessage>

  function toggleDirectory(path: string) {
    setExpandedPaths((current) => {
      const next = new Set(current)
      if (next.has(path)) {
        next.delete(path)
      } else {
        next.add(path)
      }
      return next
    })
  }

  const hitLines = hitMap.isSuccess && hitMap.data.hit_map_attached ? hitMap.data.lines : null

  return (
    <SourceShell mode={mode} onModeChange={onModeChange} showDiffToggle={showDiffToggle}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <label className="text-sm text-gray-600 dark:text-gray-300">
          {t("source_viewing_label")}
          <select className="ml-2 rounded border border-gray-300 bg-white px-2 py-1 text-sm text-gray-900 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100" onChange={(event) => onSelectRef(event.target.value)} value={payload.selected_ref}>
            {refOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
          </select>
        </label>
        {payload.tree_truncated ? <span className="text-xs text-amber-700">{t("source_tree_truncated")}</span> : null}
      </div>
      <div className="grid min-h-[36rem] overflow-hidden rounded border border-gray-200 bg-white lg:grid-cols-[20rem_minmax(0,1fr)] dark:border-gray-700 dark:bg-gray-900">
        <div className="max-h-[36rem] overflow-auto border-b border-gray-200 bg-gray-50 lg:border-b-0 lg:border-r dark:border-gray-700 dark:bg-gray-950">
          {tree.length > 0 ? tree.map((node) => (
            <SourceTreeRow
              expandedPaths={expandedPaths}
              key={node.path}
              node={node}
              onSelectPath={onSelectPath}
              onToggleDirectory={toggleDirectory}
              selectedPath={payload.selected_path}
            />
          )) : <p className="p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_no_files")}</p>}
          {payload.tree_items.length > visibleItems.length ? <p className="p-3 text-xs text-amber-700">{t("source_showing_first", { count: visibleItems.length })}</p> : null}
        </div>
        <div className="min-w-0 overflow-auto">
          {payload.file_error ? <p className="p-4 text-sm text-red-700">{payload.file_error}</p> : null}
          {payload.file ? (
            <>
              <div className="sticky top-0 flex items-center gap-3 border-b border-gray-100 bg-gray-50 px-4 py-2 font-mono text-xs text-gray-600 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-400">
                <span className="min-w-0 flex-1 truncate">{payload.file.path}</span>
                <span>{payload.file.language}</span>
                <span>{formatBytes(payload.file.size)}</span>
              </div>
              {hitLines ? (
                <CoverageAnnotatedSource content={payload.file.content} fileLanguage={fileLanguage} hitLines={hitLines} />
              ) : (
                <>
                  {hitMapAttached && !hitMap.isSuccess ? (
                    <p className="px-4 pt-2 text-xs text-gray-400 dark:text-gray-500">{t("source_coverage_loading")}</p>
                  ) : hitMapAttached === false && coverageWorkflowId != null && selectedFilePath != null ? (
                    <p className="px-4 pt-2 text-xs text-gray-400 dark:text-gray-500">{t("source_coverage_expired")}</p>
                  ) : null}
                  <pre className="m-0 overflow-x-auto p-4 text-sm leading-relaxed text-gray-900 dark:text-gray-100">
                    <code>{fileLanguage ? highlightCode(payload.file.content, fileLanguage) : payload.file.content}</code>
                  </pre>
                </>
              )}
            </>
          ) : <div className="flex h-full min-h-[20rem] items-center justify-center p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_select_file")}</div>}
        </div>
      </div>
    </SourceShell>
  )
}

function CoverageAnnotatedSource({ content, fileLanguage, hitLines }: {
  content: string
  fileLanguage: ReturnType<typeof sourceLanguage>
  hitLines: Record<string, number>
}) {
  const lines = content.split("\n")
  return (
    <table className="min-w-full border-separate border-spacing-0 font-mono text-sm" data-testid="coverage-annotated-source">
      <tbody>
        {lines.map((line, i) => {
          const lineNum = i + 1
          const hits = hitLines[String(lineNum)]
          const rowClass = hits === undefined
            ? "bg-white dark:bg-gray-950"
            : hits > 0
            ? "bg-green-50 dark:bg-green-950/30"
            : "bg-red-50 dark:bg-red-950/30"
          return (
            <tr className={rowClass} data-coverage-hits={hits} data-line={lineNum} key={lineNum}>
              <td className="w-4 select-none border-r border-gray-200 px-1 text-right text-xs text-gray-400 dark:border-gray-800 dark:text-gray-500">
                {hits === undefined ? null : hits > 0 ? (
                  <span className="text-emerald-600 dark:text-emerald-400" title={`${hits} hit${hits !== 1 ? "s" : ""}`}>✓</span>
                ) : (
                  <span className="text-red-600 dark:text-red-400" title="not covered">✗</span>
                )}
              </td>
              <td className="w-10 select-none px-2 text-right text-xs text-gray-400 dark:text-gray-600">{lineNum}</td>
              <td className="min-w-[40rem] whitespace-pre px-3 py-0.5 leading-relaxed text-gray-900 dark:text-gray-100">
                {fileLanguage ? highlightCode(line, fileLanguage) : line}
              </td>
            </tr>
          )
        })}
      </tbody>
    </table>
  )
}

function SourceShell({
  children,
  mode,
  onModeChange,
  showDiffToggle
}: {
  children: ReactNode
  mode: "browse" | "diff"
  onModeChange: (mode: "browse" | "diff") => void
  showDiffToggle: boolean
}) {
  const { t } = useT("jobs")
  return (
    <section className="space-y-3">
      {showDiffToggle ? (
        <div className="inline-flex rounded border border-gray-300 bg-white p-0.5 text-sm dark:border-gray-700 dark:bg-gray-950">
          {(["browse", "diff"] as const).map((option) => (
            <Button
              key={option}
              onClick={() => onModeChange(option)}
              size="sm"
              variant={mode === option ? "primary" : "secondary"}
            >
              {option === "browse" ? t("source_browse") : t("source_diff")}
            </Button>
          ))}
        </div>
      ) : null}
      {children}
    </section>
  )
}

function SourceDiffBrowser({
  diffAnnotations,
  mode,
  onModeChange,
  onSelectBaseRef,
  onSelectHeadRef,
  payload,
  showDiffToggle
}: {
  diffAnnotations: Record<string, Record<string, LineAnnotation>> | null
  mode: "browse" | "diff"
  onModeChange: (mode: "browse" | "diff") => void
  onSelectBaseRef: (ref: string) => void
  onSelectHeadRef: (ref: string) => void
  payload: JobSourceDiffPayload
  showDiffToggle: boolean
}) {
  const { t } = useT("jobs")
  const [selectedPath, setSelectedPath] = useState<string | null>(null)
  const selectedFile = selectedPath ? payload.files.find((file) => file.path === selectedPath) || null : null
  const refOptions = refOptionsFor(payload, [payload.base_ref, payload.head_ref])

  useEffect(() => {
    if (selectedPath && !payload.files.some((file) => file.path === selectedPath)) setSelectedPath(null)
  }, [payload.files, selectedPath])

  if (payload.diff_error) return <SourceShell mode={mode} onModeChange={onModeChange} showDiffToggle={showDiffToggle}><PanelMessage tone="error">{payload.diff_error}</PanelMessage></SourceShell>

  return (
    <SourceShell mode={mode} onModeChange={onModeChange} showDiffToggle={showDiffToggle}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-3">
          <label className="text-sm text-gray-600 dark:text-gray-300">
            {t("source_from_label")}
            <select className="ml-2 rounded border border-gray-300 bg-white px-2 py-1 text-sm text-gray-900 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100" onChange={(event) => onSelectBaseRef(event.target.value)} value={payload.base_ref || ""}>
              {refOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </select>
          </label>
          <label className="text-sm text-gray-600 dark:text-gray-300">
            {t("source_to_label")}
            <select className="ml-2 rounded border border-gray-300 bg-white px-2 py-1 text-sm text-gray-900 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100" onChange={(event) => onSelectHeadRef(event.target.value)} value={payload.head_ref || ""}>
              {refOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </select>
          </label>
        </div>
        {payload.truncated ? <span className="text-xs text-amber-700">{t("source_diff_truncated")}</span> : null}
      </div>
      <div className="grid min-h-[36rem] overflow-hidden rounded border border-gray-200 bg-white lg:grid-cols-[20rem_minmax(0,1fr)] dark:border-gray-700 dark:bg-gray-900">
        <div className="max-h-[36rem] overflow-auto border-b border-gray-200 bg-gray-50 lg:border-b-0 lg:border-r dark:border-gray-700 dark:bg-gray-950">
          {payload.files.length > 0 ? payload.files.map((file) => (
            <button
              className={`flex w-full items-center gap-2 px-3 py-1.5 text-left font-mono text-xs hover:bg-blue-50 dark:hover:bg-blue-950/40 ${selectedFile?.path === file.path ? "bg-blue-100 text-blue-700 dark:bg-blue-950/60 dark:text-blue-200" : "text-gray-700 dark:text-gray-300"}`}
              key={file.path}
              onClick={() => setSelectedPath(file.path)}
              title={`${file.path} (+${file.additions} -${file.deletions})`}
              type="button"
            >
              <SourceDiffStatusBadge status={file.status} />
              <span className="min-w-0 flex-1 truncate">{file.path}</span>
            </button>
          )) : <p className="p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_no_changed_files")}</p>}
        </div>
        <div className="min-w-0 overflow-auto">
          {selectedFile ? (
            selectedFile.patch !== null ? (
              <>
                <div className="sticky top-0 flex items-center gap-3 border-b border-gray-100 bg-gray-50 px-4 py-2 font-mono text-xs text-gray-600 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-400">
                  <span className="min-w-0 flex-1 truncate">{selectedFile.path}</span>
                  <span>+{selectedFile.additions}</span>
                  <span>-{selectedFile.deletions}</span>
                </div>
                <AgentDiff annotations={diffAnnotations?.[selectedFile.path]} diff={selectedFile.patch} />
              </>
            ) : <div className="flex h-full min-h-[20rem] items-center justify-center p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_diff_not_available")}</div>
          ) : <div className="flex h-full min-h-[20rem] items-center justify-center p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_select_diff_file")}</div>}
        </div>
      </div>
    </SourceShell>
  )
}

function SourceDiffStatusBadge({ status }: { status: string }) {
  const normalized = status.toLowerCase()
  const styles: Record<string, string> = {
    added: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/60 dark:text-emerald-200",
    modified: "bg-amber-100 text-amber-700 dark:bg-amber-950/60 dark:text-amber-200",
    removed: "bg-red-100 text-red-700 dark:bg-red-950/60 dark:text-red-200",
    renamed: "bg-blue-100 text-blue-700 dark:bg-blue-950/60 dark:text-blue-200"
  }
  const labels: Record<string, string> = { added: "A", modified: "M", removed: "D", renamed: "R" }

  return <span className={`inline-flex h-5 w-5 shrink-0 items-center justify-center rounded text-2xs font-semibold ${styles[normalized] || "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300"}`}>{labels[normalized] || normalized.slice(0, 1).toUpperCase()}</span>
}

function SourceTreeRow({
  expandedPaths,
  node,
  onSelectPath,
  onToggleDirectory,
  selectedPath
}: {
  expandedPaths: Set<string>
  node: SourceTreeNode
  onSelectPath: (path: string) => void
  onToggleDirectory: (path: string) => void
  selectedPath: string | null
}) {
  return (
    <>
      {node.file ? (
        <button
          className={`block w-full truncate py-1.5 pr-3 text-left font-mono text-xs hover:bg-blue-50 dark:hover:bg-blue-950/40 ${selectedPath === node.path ? "bg-blue-100 text-blue-700 dark:bg-blue-950/60 dark:text-blue-200" : "text-gray-700 dark:text-gray-300"}`}
          key={node.path}
          onClick={() => onSelectPath(node.path)}
          style={{ paddingLeft: `${0.75 + node.path.split("/").length * 0.75}rem` }}
          title={`${node.path} (${formatBytes(node.file.size)})`}
          type="button"
        >
          {node.name}
        </button>
      ) : (
        <button
          aria-expanded={expandedPaths.has(node.path)}
          aria-label={node.name}
          className="block w-full truncate py-1.5 pr-3 text-left font-mono text-xs font-semibold text-gray-700 hover:bg-blue-50 dark:text-gray-300 dark:hover:bg-blue-950/40"
          onClick={() => onToggleDirectory(node.path)}
          style={{ paddingLeft: `${0.75 + Math.max(node.path.split("/").length - 1, 0) * 0.75}rem` }}
          title={node.path}
          type="button"
        >
          <span aria-hidden="true" className={`mr-1 inline-block w-3 text-gray-400 transition-transform dark:text-gray-500 ${expandedPaths.has(node.path) ? "rotate-90" : ""}`}>{">"}</span>
          {node.name}
        </button>
      )}
      {!node.file && expandedPaths.has(node.path) ? node.children.map((child) => (
        <SourceTreeRow
          expandedPaths={expandedPaths}
          key={child.path}
          node={child}
          onSelectPath={onSelectPath}
          onToggleDirectory={onToggleDirectory}
          selectedPath={selectedPath}
        />
      )) : null}
    </>
  )
}
