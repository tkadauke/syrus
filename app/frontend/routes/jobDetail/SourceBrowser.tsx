import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { Dispatch, ReactNode, SetStateAction } from "react"
import { useEffect, useMemo, useState } from "react"
import { Button } from "../../components/Button"
import { Checkbox } from "../../components/Checkbox"
import { Input } from "../../components/Input"
import { Modal } from "../../components/Modal"
import { Select } from "../../components/Select"
import { useT } from "../../hooks/useT"
import { CodeBlock, renderCodeLine, useHighlightedLines } from "../../components/CodeBlock"
import { detectHighlighterLanguage } from "../../lib/highlighter"
import { fetchJobSource, fetchJobSourceDiff, fetchJobSourceFileContent, fetchWorkflowCoverageHitMap, type CoverageArtifact, type JobSourceDiffPayload, type JobSourcePayload } from "../../api/jobs"
import { DEFAULT_REVIEW_DIFF_SETTINGS, fetchReviewDiffSettings, patchReviewDiffSettings, type ReviewDiffSettings } from "../../api/reviewDiffSettings"
import { errorMessage } from "../../lib/errorMessage"
import { formatBytes } from "../../lib/format"
import type { LineAnnotation } from "../../components/diff/diffRendering"
import { ImageDiffThumbnails } from "../../components/diff/ImageDiffThumbnails"
import { ReviewableDiff, type DiffLineSelection } from "../../components/diff/ReviewableDiff"
import { refOptionsFor, sourceDiffSearch, sourceSearch } from "./sourceRefs"
import { PanelMessage } from "./components"
import { useDiffReviewFeedback } from "./DiffReviewFeedback"
import { DiffReviewVersionSelector } from "./DiffReviewVersionSelector"
import type { SourceTreeNode } from "./sourceTree"
import { buildSourceTree } from "./sourceTree"


// Source-browser tab extracted from JobDetail.tsx: the SourceTab entry point and
// its subtree — the file-tree browser, coverage-annotated source view, the source
// shell, and the source-diff browser. Depends only on leaf modules and shared UI
// imports, so it carries no circular edge back to the route file. Unused header
// imports were pruned after the move.

export function SourceTab({ canReviewDiff = false, jobId, coverageInfo, initialDiff = null }: { canReviewDiff?: boolean; jobId: string; coverageInfo: { workflowId: number; coverage: CoverageArtifact } | null; initialDiff?: { base: string; head: string } | null }) {
  const [mode, setMode] = useState<"browse" | "diff">(initialDiff ? "diff" : "browse")
  const [sourceRef, setSourceRef] = useState<string | null>(null)
  const [sourcePath, setSourcePath] = useState<string | null>(null)
  const [diffBaseRef, setDiffBaseRef] = useState<string | null>(initialDiff?.base ?? null)
  const [diffHeadRef, setDiffHeadRef] = useState<string | null>(initialDiff?.head ?? null)
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

    return <SourceDiffBrowser canReviewDiff={canReviewDiff} diffAnnotations={diffAnnotations} mode={mode} onModeChange={setMode} onSelectBaseRef={setDiffBaseRef} onSelectHeadRef={setDiffHeadRef} payload={sourceDiff.data} showDiffToggle={source.data.branch_commits.length > 0} />
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
  const fileLanguage = payload.file ? detectHighlighterLanguage(payload.file.path) : null
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
          <Select className="ml-2" fullWidth={false} onChange={(event) => onSelectRef(event.target.value)} value={payload.selected_ref}>
            {refOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
          </Select>
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
                  <CodeBlock className="m-0 overflow-x-auto p-4 text-sm leading-relaxed text-gray-900 dark:text-gray-100" code={payload.file.content} lang={fileLanguage} />
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
  fileLanguage: ReturnType<typeof detectHighlighterLanguage>
  hitLines: Record<string, number>
}) {
  const lines = content.split("\n")
  const tokenLines = useHighlightedLines(content, fileLanguage)
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
                {renderCodeLine(tokenLines?.[i], line)}
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
  canReviewDiff,
  diffAnnotations,
  mode,
  onModeChange,
  onSelectBaseRef,
  onSelectHeadRef,
  payload,
  showDiffToggle
}: {
  canReviewDiff: boolean
  diffAnnotations: Record<string, Record<string, LineAnnotation>> | null
  mode: "browse" | "diff"
  onModeChange: (mode: "browse" | "diff") => void
  onSelectBaseRef: (ref: string) => void
  onSelectHeadRef: (ref: string) => void
  payload: JobSourceDiffPayload
  showDiffToggle: boolean
}) {
  const { t } = useT("jobs")
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [selectedPath, setSelectedPath] = useState<string | null>(null)
  const [renderMode, setRenderMode] = useState<"single-file" | "continuous">("single-file")
  const settingsQuery = useQuery({
    queryKey: ["review_diff_settings"],
    queryFn: fetchReviewDiffSettings,
    staleTime: Infinity
  })
  const reviewSettings = settingsQuery.data?.review_diff_settings ?? DEFAULT_REVIEW_DIFF_SETTINGS
  const selectedFile = selectedPath ? payload.files.find((file) => file.path === selectedPath) || null : null
  const refOptions = refOptionsFor(payload, [payload.base_ref, payload.head_ref])
  const versions = payload.versions || []
  const selectedVersionId = payload.version?.id ?? null
  const latestVersionId = payload.version?.id ?? versions[versions.length - 1]?.id ?? null
  const feedback = useDiffReviewFeedback({
    baseRef: payload.base_ref,
    buildContext: sourceBrowserCommentContext,
    diffReviewVersionId: payload.version?.id,
    enabled: canReviewDiff && Boolean(payload.base_ref && payload.head_ref && payload.version?.id),
    headRef: payload.head_ref,
    jobId: payload.job_id,
    onNavigateToFile: setSelectedPath,
    surface: "job_source_diff"
  })

  useEffect(() => {
    if (selectedPath && !payload.files.some((file) => file.path === selectedPath)) setSelectedPath(null)
  }, [payload.files, selectedPath])
  useEffect(() => {
    if (feedback.selectedCommentPath) setSelectedPath(feedback.selectedCommentPath)
  }, [feedback.selectedCommentPath])

  function selectVersion(versionId: number) {
    const version = versions.find((candidate) => candidate.id === versionId)
    if (!version) return
    onSelectBaseRef(version.base_sha)
    onSelectHeadRef(version.head_sha)
  }

  if (payload.diff_error) return <SourceShell mode={mode} onModeChange={onModeChange} showDiffToggle={showDiffToggle}><PanelMessage tone="error">{payload.diff_error}</PanelMessage></SourceShell>

  return (
    <SourceShell mode={mode} onModeChange={onModeChange} showDiffToggle={showDiffToggle}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-3">
          {versions.length > 0 ? (
            <DiffReviewVersionSelector
              latestVersionId={latestVersionId}
              onChange={selectVersion}
              onRangeChange={(range) => {
                onSelectBaseRef(range.baseSha)
                onSelectHeadRef(range.headSha)
              }}
              selectedVersionId={selectedVersionId}
              versions={versions}
            />
          ) : null}
          <label className="text-sm text-gray-600 dark:text-gray-300">
            {t("source_from_label")}
            <Select className="ml-2" fullWidth={false} onChange={(event) => onSelectBaseRef(event.target.value)} value={payload.base_ref || ""}>
              {refOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </Select>
          </label>
          <label className="text-sm text-gray-600 dark:text-gray-300">
            {t("source_to_label")}
            <Select className="ml-2" fullWidth={false} onChange={(event) => onSelectHeadRef(event.target.value)} value={payload.head_ref || ""}>
              {refOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </Select>
          </label>
        </div>
        <div className="flex items-center gap-3">
          <div className="inline-flex overflow-hidden rounded border border-gray-200 text-xs dark:border-gray-700">
            <button
              className={`px-2.5 py-1 ${renderMode === "single-file" ? "bg-brand text-white" : "bg-white text-gray-600 hover:bg-gray-50 dark:bg-gray-900 dark:text-gray-300 dark:hover:bg-gray-800"}`}
              onClick={() => setRenderMode("single-file")}
              type="button"
            >
              {t("source_diff_single_file")}
            </button>
            <button
              className={`border-l border-gray-200 px-2.5 py-1 dark:border-gray-700 ${renderMode === "continuous" ? "bg-brand text-white" : "bg-white text-gray-600 hover:bg-gray-50 dark:bg-gray-900 dark:text-gray-300 dark:hover:bg-gray-800"}`}
              onClick={() => setRenderMode("continuous")}
              type="button"
            >
              {t("source_diff_continuous")}
            </button>
          </div>
          {payload.truncated ? <span className="text-xs text-amber-700">{t("source_diff_truncated")}</span> : null}
          <Button onClick={() => setSettingsOpen(true)} size="sm" variant="secondary">{t("review_settings_button")}</Button>
        </div>
      </div>
      {feedback.panel}
      <div className={`grid min-h-[36rem] overflow-hidden rounded border border-gray-200 bg-white ${reviewSettings.file_list ? "lg:grid-cols-[20rem_minmax(0,1fr)]" : ""} dark:border-gray-700 dark:bg-gray-900`}>
        {reviewSettings.file_list ? <div className="max-h-[36rem] overflow-auto border-b border-gray-200 bg-gray-50 lg:border-b-0 lg:border-r dark:border-gray-700 dark:bg-gray-950">
          {payload.files.length > 0 ? payload.files.map((file) => (
            <button
              className={`flex w-full items-center gap-2 px-3 py-1.5 text-left font-mono text-xs hover:bg-brand/10 ${selectedFile?.path === file.path ? "bg-brand/10 text-brand dark:text-brand-emphasis" : "text-gray-700 dark:text-gray-300"}`}
              key={file.path}
              onClick={() => setSelectedPath(file.path)}
              title={`${file.path} (+${file.additions} -${file.deletions})`}
              type="button"
            >
              <SourceDiffStatusBadge status={file.status} />
              <span className="min-w-0 flex-1 truncate">{file.path}</span>
              {feedback.commentCounts[file.path] ? <span className="rounded bg-amber-100 px-1.5 py-0.5 text-2xs font-semibold text-amber-800 dark:bg-amber-950 dark:text-amber-200">{feedback.commentCounts[file.path]}</span> : null}
            </button>
          )) : <p className="p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_no_changed_files")}</p>}
        </div> : null}
        <div className="min-w-0 overflow-y-auto">
          {renderMode === "continuous" || selectedFile ? (
            <ReviewableDiff
              annotations={diffAnnotations}
              comments={feedback.diffThreads}
              composingBody={feedback.composingBody}
              composingDiscussError={feedback.discussComposingError}
              composingDiscussPending={feedback.discussComposingPending}
              composingError={feedback.composingError}
              composingPending={feedback.composingPending}
              composingSelection={feedback.composingSelection}
              editingThreadBody={feedback.editingThreadBody}
              editingThreadId={feedback.editingThreadId}
              emptyState={<div className="flex h-full min-h-[20rem] items-center justify-center p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_select_diff_file")}</div>}
              files={payload.files}
              mode={renderMode}
              onCancelComposing={feedback.onCancelComposing}
              onCancelEditThread={feedback.onCancelEditThread}
              onChangeComposingBody={feedback.onChangeComposingBody}
              onChangeEditingThreadBody={feedback.onChangeEditingThreadBody}
              onCommentLine={feedback.onCommentLine}
              onDiscussComposing={feedback.onDiscussComposing}
              onLoadFileContext={payload.head_ref ? (file) => fetchJobSourceFileContent(payload.job_id, payload.head_ref!, file.path) : undefined}
              onSaveComposing={feedback.onSaveComposing}
              onSaveEditThread={feedback.onSaveEditThread}
              onSelectFile={setSelectedPath}
              onStartEditThread={feedback.onStartEditThread}
              renderImageDiff={(file) => (
                <ImageDiffThumbnails baseRef={payload.base_sha ?? payload.base_ref} file={file} headRef={payload.head_sha ?? payload.head_ref} jobId={payload.job_id} />
              )}
              reviewSettings={reviewSettings}
              selectedPath={selectedPath}
              showFileHeaders
              unavailableState={t("source_diff_not_available")}
            />
          ) : <div className="flex h-full min-h-[20rem] items-center justify-center p-4 text-sm text-gray-400 dark:text-gray-500">{t("source_select_diff_file")}</div>}
        </div>
      </div>
      {settingsOpen ? <ReviewDiffSettingsModal initialSettings={reviewSettings} onClose={() => setSettingsOpen(false)} /> : null}
    </SourceShell>
  )
}

export function ReviewDiffSettingsModal({ initialSettings, onClose }: { initialSettings: ReviewDiffSettings; onClose: () => void }) {
  const queryClient = useQueryClient()
  const { t } = useT("jobs")
  const [settings, setSettings] = useState(initialSettings)
  const mutation = useMutation({
    mutationFn: patchReviewDiffSettings,
    onSuccess: (payload) => {
      setSettings(payload.review_diff_settings)
      queryClient.setQueryData(["review_diff_settings"], payload)
    }
  })

  function updateSetting<Key extends keyof ReviewDiffSettings>(key: Key, value: ReviewDiffSettings[Key]) {
    const next = { ...settings, [key]: value }
    setSettings(next)
    mutation.mutate({ [key]: value })
  }

  return (
    <Modal className="w-full max-w-3xl rounded-[var(--radius-panel)] bg-surface p-5 shadow-[var(--shadow-panel)]" label={t("review_settings_title")} onClose={onClose} open>
      <div className="mb-4 flex items-center justify-between gap-3">
        <h2 className="text-lg font-semibold text-text-primary">{t("review_settings_title")}</h2>
        <Button onClick={onClose} size="sm" variant="secondary">{t("review_settings_close")}</Button>
      </div>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <SettingsSelect label={t("review_settings_line_wrapping")} onChange={(value) => updateSetting("line_wrapping", value as ReviewDiffSettings["line_wrapping"])} options={[["wrap", t("review_settings_wrap")], ["scroll", t("review_settings_scroll")]]} value={settings.line_wrapping} />
        <SettingsSelect label={t("review_settings_desktop_view")} onChange={(value) => updateSetting("desktop_view", value as ReviewDiffSettings["desktop_view"])} options={[["unified", t("review_settings_unified")], ["split", t("review_settings_split")]]} value={settings.desktop_view} />
        <SettingsSelect label={t("review_settings_intraline")} onChange={(value) => updateSetting("intraline_highlighting", value as ReviewDiffSettings["intraline_highlighting"])} options={[["word", t("review_settings_word")], ["off", t("review_settings_off")]]} value={settings.intraline_highlighting} />
        <SettingsSelect label={t("review_settings_whitespace")} onChange={(value) => updateSetting("whitespace", value as ReviewDiffSettings["whitespace"])} options={[["show", t("review_settings_show")], ["trim_trailing", t("review_settings_trim_trailing")]]} value={settings.whitespace} />
        <SettingsSelect label={t("review_settings_density")} onChange={(value) => updateSetting("density", value as ReviewDiffSettings["density"])} options={[["compact", t("review_settings_compact")], ["comfortable", t("review_settings_comfortable")], ["spacious", t("review_settings_spacious")]]} value={settings.density} />
        <label className="space-y-1 text-sm text-text-secondary">
          <span>{t("review_settings_tab_width")}</span>
          <Input max={8} min={2} onChange={(event) => updateSetting("tab_width", Number(event.target.value))} type="number" value={settings.tab_width} />
        </label>
        <SettingsCheckbox checked={settings.syntax_highlighting} label={t("review_settings_syntax")} onChange={(checked) => updateSetting("syntax_highlighting", checked)} />
        <SettingsCheckbox checked={settings.line_numbers} label={t("review_settings_line_numbers")} onChange={(checked) => updateSetting("line_numbers", checked)} />
        <SettingsCheckbox checked={settings.file_list} label={t("review_settings_file_list")} onChange={(checked) => updateSetting("file_list", checked)} />
      </div>
      {mutation.isError ? <p className="mt-3 text-sm text-danger-text">{t("review_settings_save_error")}</p> : null}
    </Modal>
  )
}

function SettingsSelect({ label, onChange, options, value }: { label: string; onChange: (value: string) => void; options: Array<[string, string]>; value: string }) {
  return (
    <label className="space-y-1 text-sm text-text-secondary">
      <span>{label}</span>
      <Select className="w-full" onChange={(event) => onChange(event.target.value)} value={value}>
        {options.map(([optionValue, optionLabel]) => <option key={optionValue} value={optionValue}>{optionLabel}</option>)}
      </Select>
    </label>
  )
}

function SettingsCheckbox({ checked, label, onChange }: { checked: boolean; label: string; onChange: (checked: boolean) => void }) {
  return (
    <div className="flex items-center gap-2 rounded border border-border px-3 py-2 text-sm text-text-primary">
      <Checkbox checked={checked} label={label} onChange={(event) => onChange(event.target.checked)} />
    </div>
  )
}

function sourceBrowserCommentContext(selection: DiffLineSelection) {
  return {
    source_surface: "source_browser",
    file_status: selection.file.status || null
  }
}

function SourceDiffStatusBadge({ status }: { status: string }) {
  const normalized = status.toLowerCase()
  const styles: Record<string, string> = {
    added: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/60 dark:text-emerald-200",
    modified: "bg-amber-100 text-amber-700 dark:bg-amber-950/60 dark:text-amber-200",
    removed: "bg-red-100 text-red-700 dark:bg-red-950/60 dark:text-red-200",
    renamed: "bg-brand/10 text-brand dark:text-brand-emphasis"
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
          className={`block w-full truncate py-1.5 pr-3 text-left font-mono text-xs hover:bg-brand/10 ${selectedPath === node.path ? "bg-brand/10 text-brand dark:text-brand-emphasis" : "text-gray-700 dark:text-gray-300"}`}
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
          className="block w-full truncate py-1.5 pr-3 text-left font-mono text-xs font-semibold text-gray-700 hover:bg-brand/10 dark:text-gray-300"
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
