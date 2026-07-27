import type { ChatComposeAttachment, ChatSystemAction, ChatSystemCommandAction, ChatSystemCommandHandlers, PendingSlashCommandConfirmation, WalkthroughDraft } from "./composeTypes"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { ClipboardEvent as ReactClipboardEvent, DragEvent, FormEvent, KeyboardEvent } from "react"
import { useEffect, useMemo, useRef, useState } from "react"
import { useNavigate } from "react-router-dom"
import "@excalidraw/excalidraw/index.css"
import { GeminiSetupSheet } from "../../components/GeminiSetupSheet"
import { AnalyzingHint, annotationHoldLabel, annotationIdleHintKind, annotationShortcutLabel, formatClock, RECORDER_WARNING_SECONDS, shouldShowAnnotationSurfaceNote, useNativeRecorderHud, useWalkthroughRecorder, WalkthroughRecorderHUD } from "../../components/WalkthroughRecorder"
import { isWalkthroughVideoFile, MAX_WALKTHROUGH_BYTES, MAX_WALKTHROUGH_DURATION_SECONDS, measureVideoDuration, retryVideoWalkthrough, uploadVideoWalkthrough } from "../../api/videoWalkthroughs"
import { refreshRecentChats, updateRecentChatCache } from "../../lib/chatCache"
import { attachChatRepository, branchChat, clearChatHistory, createChat, createChatTopicBookmark, createScratchpadItem, deleteQueuedChatMessage, deleteChatAttachment, enqueueChatMessage, fetchChatWhiteboard, patchChatWhiteboard, rejectChatProposal, renameChat, sendChatMessage, shareChat, stopChat, updateChatMode, updateChatModel, updateChatPinned, updateQueuedChatMessage, type ChatBranchPayload, type ChatCreatedPayload, type ChatMode, type ChatPayload, type ChatProposal, type ChatQueuedMessage, type ShareChatPayload } from "../../api/chats"
import { postJobCommand } from "../../api/jobs"
import { CloseIcon } from "../../components/CloseIcon"
import { EnqueueIcon } from "../../components/EnqueueIcon"
import { ImageAnnotationModal } from "../../components/ImageAnnotationModal"
import { SendIcon } from "../../components/SendIcon"
import { StopIcon } from "../../components/StopIcon"
import { filterSlashCommands, findSlashCommand, slashCommandDescription, slashCommandPrompt, slashCommandQuery, slashCommandSignature, type SlashCommand, type SlashCommandMatch } from "../../lib/slashCommands"
import { createReportIssue } from "../../api/reportIssues"
import { useT } from "../../hooks/useT"
import { errorMessage } from "../../lib/errorMessage"
import { type ChatQueryKey, CHAT_ATTACHMENT_MAX_BYTES, CHAT_ATTACHMENT_TOTAL_MAX_BYTES, CHAT_COMPOSE_MAX_ROWS, CHAT_DRAFT_KEY_PREFIX, GHOST_SUGGESTION_TAB_GRACE_MS } from "./constants"
import { appendSearch, chatDisplayTitle, currentRecentChat, isDesktopChatViewport, primaryButton, secondaryButton, numericArg, parsePixelValue, providerLabel, withRoutePrefix } from "./utils"
import { ScratchpadPanel } from "./ScratchpadPanel"
import { AddAttachment, Attachments } from "./Attachments"
import { lastAssistantRenderedMessage } from "./streamBuilders"
import { PencilIcon, UploadIcon } from "./icons"
import { isAgentActive } from "./messageDisplay"
import { storeWorkspacePreference } from "./workspaceTabs"




// Chat composer extracted from Chat.tsx: the Compose input component and its whole
// support cast — the report-issue dialog, the slash-command palette/confirmation,
// the queued-message list, the stop-generation button, and the compose-only
// textarea/enter/proposal helpers. Compose is the entry point ChatColumn renders.
// Depends only on leaf modules and shared UI imports; unused header imports pruned.

export function Compose({ autoFocus = false, chatId, commandHandlers, payload, prefix, queryKey, showAttachedRepositories = false, onNotice, onMessageSent }: { autoFocus?: boolean; chatId: string; commandHandlers: ChatSystemCommandHandlers; payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; showAttachedRepositories?: boolean; onNotice: (message: string | null) => void; onMessageSent?: () => void }) {
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const { t } = useT("chat")
  const [text, setText] = useState(() => {
    try {
      return window.localStorage.getItem(CHAT_DRAFT_KEY_PREFIX + chatId) || ""
    } catch (_error) {
      return ""
    }
  })
  const [attachments, setAttachments] = useState<ChatComposeAttachment[]>([])
  const [annotatingIndex, setAnnotatingIndex] = useState<number | null>(null)
  const [attachmentError, setAttachmentError] = useState<string | null>(null)
  const [isDragOver, setIsDragOver] = useState(false)
  const [pendingConfirmation, setPendingConfirmation] = useState<PendingSlashCommandConfirmation | null>(null)
  const [activeCommandIndex, setActiveCommandIndex] = useState(0)
  const [clearConfirmationOpen, setClearConfirmationOpen] = useState(false)
  const [reportDialogOpen, setReportDialogOpen] = useState(false)
  const [attachmentPopoverOpen, setAttachmentPopoverOpen] = useState(false)
  // One walkthrough video per message (v1). The chip above the composer
  // narrates its lifecycle: ready -> uploading(pct) -> analyzing -> failed;
  // an analyzed walkthrough clears the chip (its turn appears in the thread).
  const [walkthrough, setWalkthrough] = useState<WalkthroughDraft | null>(null)
  // Reassuring lines the chip rotates through while Gemini analyzes — the wait
  // can run minutes, so a single frozen line reads as stuck. The first entry is
  // the original static copy so nothing regresses if rotation is suppressed
  // (single message / prefers-reduced-motion).
  const walkthroughAnalyzingHints = useMemo(
    () => [
      t("walkthrough_analyzing"),
      t("walkthrough_analyzing_narration"),
      t("walkthrough_analyzing_issues"),
      t("walkthrough_analyzing_screenshots"),
      t("walkthrough_analyzing_finishing")
    ],
    [t]
  )
  const [geminiSheetOpen, setGeminiSheetOpen] = useState(false)
  const pendingVideoRef = useRef<File | null>(null)
  const walkthroughKeyRef = useRef(0)
  const [scratchpadOpen, setScratchpadOpen] = useState(false)
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const fileInputRef = useRef<HTMLInputElement | null>(null)
  const attachmentPopoverRef = useRef<HTMLDivElement | null>(null)
  const addAttachmentButtonRef = useRef<HTMLButtonElement | null>(null)
  const submitWithEnter = useSubmitChatWithEnter()
  const search = queryKey[2]
  const agentActive = isAgentActive(payload)
  const queuedMessages = payload.queued_messages || []
  // Textarea right padding grows with each button visible in the embedded group
  // (Send → Stash → Stop, left-to-right). Send is leftmost so its left edge moves
  // furthest from the right edge as more buttons appear: ~40 px (1), ~76 px (2),
  // ~112 px (3). Each class adds a comfortable buffer above those thresholds.
  const inlineButtonCount = 1 + (text.trim().length > 0 ? 1 : 0) + (agentActive && !payload.switching_provider ? 1 : 0)
  const textareaPr = inlineButtonCount >= 3 ? "pr-32" : inlineButtonCount === 2 ? "pr-24" : "pr-12"
  const [dismissedSuggestion, setDismissedSuggestion] = useState<string | null>(null)
  const suggestionShownAtRef = useRef(0)
  const commandQuery = slashCommandQuery(text)
  const matchingCommands = useMemo(() => commandQuery == null ? [] : filterSlashCommands(commandQuery), [commandQuery])
  const pendingProposals = useMemo(() => {
    const seenIds = new Set<number>()
    return payload.messages.filter(
      (item): item is typeof item & { proposal: ChatProposal } => {
        if (item.type !== "message" || item.proposal?.proposed !== true) return false
        if (seenIds.has(item.proposal.id)) return false
        seenIds.add(item.proposal.id)
        return true
      }
    )
  }, [payload.messages])
  const [jumpIndex, setJumpIndex] = useState(0)
  const attachedRepositories = payload.attachment_groups.repositories

  useEffect(() => {
    if (text.length > 0) {
      storeWorkspacePreference(CHAT_DRAFT_KEY_PREFIX + chatId, text)
      return
    }

    try {
      window.localStorage.removeItem(CHAT_DRAFT_KEY_PREFIX + chatId)
    } catch (_error) {
      // Local storage can be unavailable in hardened browser modes.
    }
  }, [chatId, text])

  const send = useMutation({
    mutationFn: (messageText: string) => agentActive
      ? enqueueChatMessage(appendSearch(payload.paths.app_enqueue_message_path, search), messageText, attachments)
      : sendChatMessage(appendSearch(payload.paths.app_message_path, search), messageText, attachments),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      updateRecentChatCache(queryClient, currentRecentChat(updated) || updated.chat, { prepend: true })
      setText("")
      try {
        window.localStorage.removeItem(CHAT_DRAFT_KEY_PREFIX + chatId)
      } catch (_error) {
        // Local storage can be unavailable in hardened browser modes.
      }
      setAttachments([])
      setAttachmentError(null)
      setPendingConfirmation(null)
      onNotice(null)
      onMessageSent?.()
    }
  })
  const systemAction = useMutation<ChatPayload | ChatCreatedPayload | ChatBranchPayload | ShareChatPayload, Error, ChatSystemAction>({
    mutationFn: (action) => {
      if (action.kind === "rename") return renameChat(appendSearch(payload.paths.app_rename_path, search), action.title)
      if (action.kind === "clear") return clearChatHistory(appendSearch(payload.paths.app_clear_path, search))
      if (action.kind === "new") return createChat({ repositoryId: payload.chat.repository ? String(payload.chat.repository.id) : "", text: "" })
      if (action.kind === "pin") return updateChatPinned(chatId, action.pinned)
      if (action.kind === "branch") return branchChat(appendSearch(payload.paths.app_branch_path, search))
      if (action.kind === "share") return shareChat(appendSearch(payload.paths.app_share_path, search))
      return attachChatRepository(appendSearch(payload.paths.app_attachments_path, search), action.slug)
    },
    onSuccess: async (updated, action) => {
      if (action.kind === "new") {
        const created = updated as ChatCreatedPayload
        updateRecentChatCache(queryClient, created.chat, { prepend: true })
        refreshRecentChats(queryClient)
        navigate(withRoutePrefix(created.redirect_to, prefix))
        return
      }

      if (action.kind === "branch") {
        const branched = updated as ChatBranchPayload
        refreshRecentChats(queryClient)
        navigate(withRoutePrefix(branched.app_path, prefix))
        return
      }

      if (action.kind === "share") {
        await navigator.clipboard.writeText((updated as ShareChatPayload).share_url)
        setText("")
        onNotice("Share link copied to clipboard")
        return
      }

      const chatPayload = updated as ChatPayload
      queryClient.setQueryData(queryKey, chatPayload)
      updateRecentChatCache(queryClient, chatPayload.chat)
      refreshRecentChats(queryClient)
      setText("")
      setClearConfirmationOpen(false)
      onNotice(action.kind === "pin" ? (action.pinned ? "Chat pinned" : "Chat unpinned") : chatPayload.message || null)
      if (action.kind === "attach") commandHandlers.openAttachments()
    }
  })
  const systemCommandAction = useMutation<{ payload?: ChatPayload; notice: string; jobId?: string }, Error, ChatSystemCommandAction>({
    mutationFn: async (action) => {
      if (action.kind === "bookmark") {
        const updated = await createChatTopicBookmark(appendSearch(payload.paths.app_bookmarks_path, search), action.label)
        return { payload: updated, notice: `Bookmark saved: ${action.label}` }
      }

      if (action.kind === "discard") {
        const updated = await rejectChatProposal(appendSearch(action.path, search))
        return { payload: updated, notice: "Proposal discarded" }
      }

      if (action.kind === "job") {
        const path = `/api/v1/app/jobs/${encodeURIComponent(action.jobId)}/${action.action === "cancel" ? "cancel" : "run_again"}`
        await postJobCommand(path)
        return {
          jobId: action.jobId,
          notice: action.action === "cancel" ? "Job cancelled" : "Job queued for retry"
        }
      }

      const current = await fetchChatWhiteboard(appendSearch(payload.paths.app_whiteboard_path, search))
      let result = await patchChatWhiteboard(appendSearch(payload.paths.app_whiteboard_path, search), {
        elements: [],
        appState: {},
        files: {},
        expected_version: current.version
      })
      if (result.status === 409) {
        result = await patchChatWhiteboard(appendSearch(payload.paths.app_whiteboard_path, search), {
          elements: [],
          appState: {},
          files: {},
          expected_version: result.payload.version
        })
      }
      queryClient.setQueryData(queryKey, (currentPayload: ChatPayload | undefined) => currentPayload ? {
        ...currentPayload,
        whiteboard: {
          version: result.payload.version,
          elements: result.payload.scene_json.elements,
          appState: result.payload.scene_json.appState,
          files: result.payload.scene_json.files
        }
      } : currentPayload)
      return { notice: "Canvas cleared" }
    },
    onSuccess: (result, action) => {
      if (result.payload) {
        queryClient.setQueryData(queryKey, result.payload)
        updateRecentChatCache(queryClient, result.payload.chat)
      }
      if (action.kind === "discard") {
        void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
      }
      if (action.kind === "job" && result.jobId) {
        void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
        void queryClient.invalidateQueries({ queryKey: ["jobs", result.jobId] })
      }
      setText("")
      setPendingConfirmation(null)
      onNotice(result.notice)
    },
    onError: (error) => {
      onNotice(errorMessage(error, "Command failed."))
    }
  })
  const detachRepository = useMutation({
    mutationFn: (path: string) => deleteChatAttachment(appendSearch(path, search)),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })
  const stash = useMutation({
    mutationFn: (content?: string) => createScratchpadItem(chatId, content ?? text),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setText("")
    }
  })
  const updateModel = useMutation({
    mutationFn: (model: string | null) => updateChatModel(chatId, model),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
    }
  })
  const commandPaletteOpen = commandQuery != null
    && matchingCommands.length > 0
    && !send.isPending
    && !systemAction.isPending
    && !systemCommandAction.isPending
    && pendingConfirmation == null
  const suggestedNextStep = payload.chat.suggested_next_step || null
  const ghostSuggestion = text.length === 0 && !send.isPending && suggestedNextStep && suggestedNextStep !== dismissedSuggestion
    ? suggestedNextStep
    : null

  function submitMessage() {
    if (send.isPending || systemAction.isPending || systemCommandAction.isPending) return
    if (walkthrough?.status === "ready") {
      // A walkthrough and image/PDF attachments can't share one send: the
      // video goes to Gemini, the attachments to the chat agent — silently
      // splitting them (and leaking the images to the next message) is the
      // review finding. Block explicitly instead.
      if (attachments.length > 0) {
        setAttachmentError(t("walkthrough_no_other_attachments"))
        return
      }
      // Send commits the walkthrough: the video uploads with the typed text
      // riding along as the user's note; the analysis turn carries both.
      void uploadWalkthrough(text)
      return
    }
    // Any media makes the message sendable on its own — a bare attachment (or
    // walkthrough) IS the message, no text required.
    if (text.trim().length === 0 && attachments.length === 0) return
    const attachmentValidationError = attachmentValidationMessage(attachments)
    if (attachmentValidationError) {
      setAttachmentError(attachmentValidationError)
      return
    }
    const commandMatch = findSlashCommand(text)
    if (commandMatch?.command.requiresConfirmation) {
      onNotice(null)
      setPendingConfirmation({ commandName: commandMatch.command.name, text: text.trim() })
      return
    }

    if (commandMatch?.command.kind === "system") {
      onNotice(null)
      setPendingConfirmation(null)
      handleSystemSlashCommand(commandMatch)
      return
    }

    onNotice(null)
    setPendingConfirmation(null)
    send.mutate(slashCommandPrompt(text))
  }

  function jumpToPending() {
    const target = pendingProposals[jumpIndex % pendingProposals.length]
    if (!target) return

    document.getElementById(`chat_message_${target.id}`)?.scrollIntoView({ behavior: "smooth", block: "start" })
    setJumpIndex((index) => index + 1)
  }

  function handleSystemSlashCommand(commandMatch: SlashCommandMatch) {
    const command = commandMatch.command
    const argsText = commandMatch.argsText
    if (command.name === "/rename") {
      if (!argsText) {
        onNotice("Usage: /rename <name>")
        return
      }

      systemAction.mutate({ kind: "rename", title: argsText })
      return
    }

    if (command.name === "/clear") {
      setText("")
      setClearConfirmationOpen(true)
      onNotice(null)
      return
    }

    if (command.name === "/new") {
      systemAction.mutate({ kind: "new" })
      return
    }

    if (command.name === "/branch") {
      setText("")
      onNotice("Branching chat…")
      systemAction.mutate({ kind: "branch" })
      return
    }

    if (command.name === "/bookmarks") {
      commandHandlers.openBookmarks()
      setText("")
      onNotice(null)
      return
    }

    if (command.name === "/attach") {
      if (argsText) {
        systemAction.mutate({ kind: "attach", slug: argsText })
      } else {
        commandHandlers.openAttachments()
        setText("")
        onNotice(null)
      }
      return
    }

    if (command.name === "/settings") {
      commandHandlers.openSettings()
      setText("")
      onNotice(null)
      return
    }

    if (command.name === "/jobs") {
      const path = argsText ? `/jobs?q=${encodeURIComponent(argsText)}` : "/jobs"
      navigate(withRoutePrefix(path, prefix))
      setText("")
      return
    }

    if (command.name === "/job") {
      const id = numericArg(argsText)
      if (!id) {
        onNotice("Usage: /job <id>")
        return
      }

      navigate(withRoutePrefix(`/jobs/${id}`, prefix))
      setText("")
      return
    }

    if (command.name === "/epic") {
      const id = numericArg(argsText)
      if (!id) {
        onNotice("Usage: /epic <id>")
        return
      }

      navigate(withRoutePrefix(`/epics/${id}`, prefix))
      setText("")
      return
    }

    if (command.name === "/prs") {
      if (!payload.chat.repository) {
        onNotice("Attach a repository to view pull requests.")
        return
      }

      navigate(withRoutePrefix(`/repositories/${payload.chat.repository.id}`, prefix))
      setText("")
      return
    }

    if (command.name === "/issues") {
      if (!payload.chat.repository) {
        onNotice("Attach a repository to view issues.")
        return
      }

      navigate(withRoutePrefix(`/repositories/${payload.chat.repository.id}?tab=github_issues&state=open`, prefix))
      setText("")
      return
    }

    if (command.name === "/proposals") {
      if (!scrollToLastProposalCard()) onNotice("No proposal cards found.")
      setText("")
      return
    }

    if (command.name === "/bookmark") {
      if (!argsText) {
        onNotice("Usage: /bookmark <label>")
        return
      }

      systemCommandAction.mutate({ kind: "bookmark", label: argsText })
      return
    }

    if (command.name === "/discard") {
      const proposal = findProposalBySlug(payload, argsText)
      if (!proposal) {
        onNotice(`Proposal not found: ${argsText}`)
        return
      }

      systemCommandAction.mutate({ kind: "discard", path: proposal.app_reject_path })
      return
    }

    if (command.name === "/cancel" || command.name === "/retry") {
      const id = numericArg(argsText)
      if (!id) {
        onNotice(`Usage: ${command.name} <id>`)
        return
      }

      systemCommandAction.mutate({ kind: "job", action: command.name === "/cancel" ? "cancel" : "retry", jobId: id })
      return
    }

    if (command.name === "/clear-canvas") {
      systemCommandAction.mutate({ kind: "clear-canvas" })
      return
    }

    if (command.name === "/copy") {
      const lastAssistantMessage = lastAssistantRenderedMessage(payload.messages)
      if (!lastAssistantMessage) {
        onNotice("No assistant response to copy")
        return
      }

      void navigator.clipboard.writeText(lastAssistantMessage.text)
      setText("")
      onNotice("Copied to clipboard")
      return
    }

    if (command.name === "/search") {
      const path = argsText ? `/chats/search?q=${encodeURIComponent(argsText)}` : "/chats/search"
      navigate(withRoutePrefix(path, prefix))
      setText("")
      onNotice(null)
      return
    }

    if (command.name === "/report") {
      setReportDialogOpen(true)
      setText("")
      onNotice(null)
      return
    }

    if (command.name === "/pin") {
      systemAction.mutate({ kind: "pin", pinned: !payload.chat.pinned })
      return
    }

    if (command.name === "/share") {
      systemAction.mutate({ kind: "share" })
      return
    }

    if (command.name === "/scratch") {
      if (argsText) {
        stash.mutate(argsText, { onSuccess: () => onNotice("Stashed to scratch pad") })
      } else {
        setScratchpadOpen(true)
        setText("")
        onNotice(null)
      }
      return
    }

    setText("")
  }

  function confirmPendingSlashCommand() {
    if (!pendingConfirmation || send.isPending || systemCommandAction.isPending) return

    onNotice(null)
    const commandMatch = findSlashCommand(pendingConfirmation.text)
    if (commandMatch?.command.kind === "system") {
      handleSystemSlashCommand(commandMatch)
      return
    }

    send.mutate(pendingConfirmation.text)
  }

  function cancelPendingSlashCommand() {
    setPendingConfirmation(null)
    textareaRef.current?.focus()
  }

  function attachmentValidationMessage(nextAttachments: ChatComposeAttachment[]) {
    if (nextAttachments.some((attachment) => attachment.size > CHAT_ATTACHMENT_MAX_BYTES)) {
      return "Each attachment must be 5 MB or smaller."
    }

    const totalBytes = nextAttachments.reduce((sum, attachment) => sum + attachment.size, 0)
    if (totalBytes > CHAT_ATTACHMENT_TOTAL_MAX_BYTES) {
      return "Attachments must total 20 MB or less."
    }

    return null
  }

  // Route an incoming video (drag, picker, or a finished recording) into the
  // walkthrough draft: gate on Gemini config, duration, and size — gently,
  // with specific copy, before any bytes move.
  //
  // `knownDuration` comes from the recorder's own clock (measureVideoDuration
  // returns null for MediaRecorder webm, whose metadata duration is Infinity),
  // so recorded videos still trip the ≥12-min low-resolution gate.
  // `assumeConfigured` is set by the post-setup handoff: the calling render's
  // payload.gemini_configured is still stale (the refetch hasn't landed), but
  // the key was just saved — re-checking it would loop the setup sheet.
  async function intakeWalkthroughVideo(
    file: File,
    options: { knownDuration?: number | null; assumeConfigured?: boolean } = {}
  ) {
    // Labs flag: every video intake path (drag-in, file picker, recorder)
    // funnels through here, so one check gates them all.
    if (!payload.walkthroughs_enabled) {
      setAttachmentError(t("walkthrough_disabled"))
      return
    }
    if (!options.assumeConfigured && !payload.gemini_configured) {
      pendingVideoRef.current = file
      setGeminiSheetOpen(true)
      return
    }

    // Never clobber an in-flight walkthrough: replacing during upload would
    // orphan the running XHR, and during analysis would lose the server row.
    // Only a settled draft (ready/failed) is replaceable.
    if (walkthrough && (walkthrough.status === "uploading" || walkthrough.status === "analyzing")) {
      setAttachmentError(t("walkthrough_one_at_a_time"))
      return
    }

    if (file.size > MAX_WALKTHROUGH_BYTES) {
      setAttachmentError(t("walkthrough_too_large"))
      return
    }

    const durationSeconds = options.knownDuration ?? (await measureVideoDuration(file))
    if (durationSeconds && durationSeconds > MAX_WALKTHROUGH_DURATION_SECONDS) {
      setAttachmentError(t("walkthrough_too_long", { limit: formatClock(MAX_WALKTHROUGH_DURATION_SECONDS), actual: formatClock(durationSeconds) }))
      return
    }

    setAttachmentError(null)
    walkthroughKeyRef.current += 1
    setWalkthrough({ key: walkthroughKeyRef.current, file, filename: file.name || "walkthrough.webm", durationSeconds, status: "ready", percent: 0 })
  }

  const recorder = useWalkthroughRecorder({
    onFinished: ({ blob, mimeType, durationSeconds }) => {
      const extension = mimeType.includes("mp4") ? "mp4" : "webm"
      const file = new File([blob], `walkthrough-${new Date().toISOString().slice(0, 19).replaceAll(":", "-")}.${extension}`, { type: mimeType })
      // Pass the recorder's measured duration — the webm blob can't be
      // re-measured, so this is the only reliable source for the gate.
      void intakeWalkthroughVideo(file, { knownDuration: durationSeconds })
    }
  })

  function startWalkthroughRecording() {
    setAttachmentPopoverOpen(false)
    if (!payload.walkthroughs_enabled) {
      setAttachmentError(t("walkthrough_disabled"))
      return
    }
    if (!payload.gemini_configured) {
      setGeminiSheetOpen(true)
      return
    }
    void recorder.start()
  }

  // In the desktop shell, drive the FLOATING recording HUD (a separate
  // always-on-top, draggable window) so the controls live outside the Syrus
  // window and stay reachable while the user demonstrates another app. Returns
  // false in a plain browser, where the in-page WalkthroughRecorderHUD is used.
  const recording = recorder.state.phase === "recording"
  const recorderMicLive = recorder.state.phase === "recording" ? recorder.state.micLive : true
  // Hint text depends on the live annotation mode: HOLD (native hook) reads
  // "Hold ⌃ to draw", TAP (fallback) reads "⌘⇧A to draw" — and when hold
  // failed only for the macOS Accessibility permission, the idle hint nudges
  // the user to grant it (the tap shortcut keeps working meanwhile).
  const annotationIdleKind = annotationIdleHintKind(recorder.annotationHold, recorder.annotationReason)
  const annotationHintIdle =
    annotationIdleKind === "hold"
      ? t("walkthrough_annotate_hold_hint", { key: annotationHoldLabel() })
      : annotationIdleKind === "accessibility"
        ? t("walkthrough_annotate_accessibility_hint", { shortcut: annotationShortcutLabel() })
        : t("walkthrough_annotate_hint", { shortcut: annotationShortcutLabel() })
  const annotationHintDrawing = recorder.annotationHold
    ? t("walkthrough_annotate_hold_drawing", { key: annotationHoldLabel() })
    : t("walkthrough_annotate_drawing")
  const nativeRecorderHud = useNativeRecorderHud({
    recording,
    state: {
      clock: formatClock(recorder.elapsed),
      remaining: t("walkthrough_remaining", { clock: formatClock(Math.max(0, MAX_WALKTHROUGH_DURATION_SECONDS - recorder.elapsed)) }),
      remainingWarn: recorder.elapsed >= RECORDER_WARNING_SECONDS,
      noMic: recorderMicLive ? undefined : t("walkthrough_no_mic"),
      hint: recorder.annotationAvailable
        ? (recorder.drawing ? annotationHintDrawing : annotationHintIdle)
        : undefined,
      drawing: recorder.drawing,
      stopLabel: t("walkthrough_stop"),
      discardLabel: t("walkthrough_discard"),
      penLabel: t("walkthrough_hud_pen")
    },
    onStop: () => recorder.stop(),
    onDiscard: () => recorder.stop({ discard: true })
  })

  // Analysis progress arrives over AppUserChannel (video_walkthrough.* app
  // events re-dispatched as a DOM event by applyAppEvent).
  useEffect(() => {
    function onWalkthroughEvent(event: Event) {
      const detail = (event as CustomEvent<{ id: number; state: string; error_message: string | null; chat_session_id: number }>).detail
      if (!detail || detail.chat_session_id !== payload.chat.id) return

      // A walkthrough finishing frees the composer — clear any lingering
      // walkthrough-scoped error (e.g. a one-at-a-time rejection) so it can't
      // keep the send button disabled for the next ordinary message.
      if (detail.state === "analyzed") setAttachmentError(null)

      // A terminal state changes the chat payload's video_walkthroughs list
      // (which powers the Media panel); the app-event only carries the walkthrough
      // id/state, so refetch the payload to refresh the panel + the delivered turn.
      if (detail.state === "analyzed" || detail.state === "failed") {
        void queryClient.invalidateQueries({ queryKey })
      }

      setWalkthrough((current) => {
        if (!current || current.id == null || current.id !== detail.id) return current
        if (detail.state === "analyzed") {
          onNotice(t("walkthrough_analyzed"))
          return null // its turn appears in the thread
        }
        if (detail.state === "failed") {
          return { ...current, status: "failed", error: detail.error_message || t("walkthrough_failed_generic") }
        }
        return { ...current, status: "analyzing" }
      })
    }

    window.addEventListener("syrus:video-walkthrough", onWalkthroughEvent)
    return () => window.removeEventListener("syrus:video-walkthrough", onWalkthroughEvent)
  }, [payload.chat.id, onNotice, t, queryClient, queryKey])

  async function uploadWalkthrough(note: string) {
    if (!walkthrough || walkthrough.status !== "ready") return

    // Every state update from here on is keyed to THIS draft — if the user
    // replaces the walkthrough (only possible once it's back to a settled
    // state), a late resolution from the old upload can't corrupt the new one.
    const activeKey = walkthrough.key
    const keyed = (updater: (current: WalkthroughDraft) => WalkthroughDraft | null) =>
      setWalkthrough((current) => (current && current.key === activeKey ? updater(current) : current))

    // Clear the composer at the START of the upload, not after it resolves:
    // the text has been captured as the note, so leaving it lets a second
    // Enter double-send it and destroys a draft typed during the upload.
    setText("")
    try {
      window.localStorage.removeItem(CHAT_DRAFT_KEY_PREFIX + chatId)
    } catch (_error) {
      // Local storage can be unavailable in hardened browser modes.
    }

    keyed((current) => ({ ...current, status: "uploading", percent: 0 }))
    try {
      const { video_walkthrough } = await uploadVideoWalkthrough({
        chatSessionId: payload.chat.id,
        file: walkthrough.file,
        filename: walkthrough.filename,
        durationSeconds: walkthrough.durationSeconds,
        note: note.trim() || undefined,
        onProgress: (percent) => {
          keyed((current) => (current.status === "uploading" ? { ...current, percent } : current))
        }
      })
      keyed((current) => ({ ...current, status: "analyzing", id: video_walkthrough.id }))
    } catch (error) {
      const message = error instanceof Error ? error.message : t("walkthrough_failed_generic")
      keyed((current) => ({ ...current, status: "failed", error: message }))
    }
  }

  function retryWalkthroughAnalysis() {
    if (!walkthrough?.id) return
    setWalkthrough((current) => (current ? { ...current, status: "analyzing", error: undefined } : current))
    retryVideoWalkthrough(walkthrough.id).catch((error: unknown) => {
      const message = error instanceof Error ? error.message : t("walkthrough_failed_generic")
      setWalkthrough((current) => (current ? { ...current, status: "failed", error: message } : current))
    })
  }

  // Paste-to-attach, ChatGPT/Claude style: an image (or any file) on the
  // clipboard becomes a composer attachment through the SAME funnel as the
  // picker and drag-in — inheriting size validation, the walkthrough video
  // split, and the one-at-a-time guard. Plain text pastes fall through to the
  // browser's default insert.
  function handlePaste(event: ReactClipboardEvent<HTMLTextAreaElement>) {
    const clipboard = event.clipboardData
    if (!clipboard) return

    let files = Array.from(clipboard.files || [])
    if (files.length === 0) {
      // Safari sometimes exposes pasted images only through items[].
      files = Array.from(clipboard.items || [])
        .filter((entry) => entry.kind === "file")
        .map((entry) => entry.getAsFile())
        .filter((file): file is File => file != null)
    }
    if (files.length === 0) return

    event.preventDefault()
    handleAttachmentChange(files)
  }

  function handleAttachmentChange(files: FileList | File[] | null) {
    let selectedFiles = Array.from(files || [])
    if (fileInputRef.current) fileInputRef.current.value = ""
    if (selectedFiles.length === 0) return

    // Videos take the walkthrough path (real upload + Gemini analysis) —
    // never the base64 message-attachment path.
    const video = payload.walkthroughs_enabled ? selectedFiles.find(isWalkthroughVideoFile) : undefined
    if (video) {
      void intakeWalkthroughVideo(video)
      selectedFiles = selectedFiles.filter((file) => !isWalkthroughVideoFile(file))
      if (selectedFiles.length === 0) return
    }

    const nextAttachments = [
      ...attachments,
      ...selectedFiles.map((file) => ({
        name: file.name,
        mimeType: file.type || "application/octet-stream",
        dataUrl: "",
        size: file.size
      }))
    ]
    const validationError = attachmentValidationMessage(nextAttachments)
    if (validationError) {
      setAttachmentError(validationError)
      return
    }

    void Promise.all(selectedFiles.map(readAttachmentFile)).then((newAttachments) => {
      setAttachments((current) => [...current, ...newAttachments])
      setAttachmentError(null)
    }).catch(() => setAttachmentError("Unable to read the selected attachment."))
  }

  function handleDragOver(event: DragEvent<HTMLFormElement>) {
    event.preventDefault()
    event.stopPropagation()
  }

  function handleDragEnter(event: DragEvent<HTMLFormElement>) {
    event.preventDefault()
    event.stopPropagation()
    setIsDragOver(true)
  }

  function handleDragLeave(event: DragEvent<HTMLFormElement>) {
    event.preventDefault()
    event.stopPropagation()
    if (event.currentTarget.contains(event.relatedTarget as Node | null)) return

    setIsDragOver(false)
  }

  function handleDrop(event: DragEvent<HTMLFormElement>) {
    event.preventDefault()
    event.stopPropagation()
    setIsDragOver(false)
    if (event.dataTransfer.files.length === 0) return

    handleAttachmentChange(event.dataTransfer.files)
  }

  function removeAttachment(index: number) {
    setAttachments((current) => current.filter((_, attachmentIndex) => attachmentIndex !== index))
    setAnnotatingIndex((current) => {
      if (current == null) return current
      if (current === index) return null
      return current > index ? current - 1 : current
    })
    setAttachmentError(null)
  }

  function openAttachmentFilePicker() {
    setAttachmentPopoverOpen(false)
    fileInputRef.current?.click()
  }

  function focusAttachmentPopoverItem(direction: 1 | -1) {
    const popover = attachmentPopoverRef.current
    if (!popover) return

    const focusable = Array.from(popover.querySelectorAll<HTMLElement>("button:not(:disabled), input:not(:disabled), select:not(:disabled), [tabindex]:not([tabindex='-1'])"))
      .filter((element) => element.offsetParent !== null || element === document.activeElement)
    if (focusable.length === 0) return

    const activeIndex = focusable.indexOf(document.activeElement as HTMLElement)
    const nextIndex = activeIndex === -1 ? 0 : (activeIndex + direction + focusable.length) % focusable.length
    focusable[nextIndex]?.focus()
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    submitMessage()
  }

  function handleAttachmentPopoverKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === "Escape") {
      event.preventDefault()
      setAttachmentPopoverOpen(false)
      addAttachmentButtonRef.current?.focus()
      return
    }

    if (event.key === "ArrowDown") {
      event.preventDefault()
      focusAttachmentPopoverItem(1)
      return
    }

    if (event.key === "ArrowUp") {
      event.preventDefault()
      focusAttachmentPopoverItem(-1)
    }
  }

  function acceptGhostSuggestion(suggestion: string) {
    updateText(suggestion)
    const textarea = textareaRef.current
    if (!textarea) return

    window.requestAnimationFrame(() => {
      textarea.setSelectionRange(suggestion.length, suggestion.length)
    })
  }

  function handleKeyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
    // Only plain Tab (never Shift+Tab or a modifier chord) accepts the
    // ghost suggestion, and only while the focused composer is empty
    // with the ghost rendered (both implied by `ghostSuggestion` on
    // this textarea's own handler). A suggestion that appeared within
    // the grace period does not intercept — the user was mid-Tab
    // navigation, so the keystroke keeps its default focus behavior.
    if (ghostSuggestion && event.key === "Tab" && !event.shiftKey && !event.altKey && !event.ctrlKey && !event.metaKey) {
      if (Date.now() - suggestionShownAtRef.current < GHOST_SUGGESTION_TAB_GRACE_MS) return

      event.preventDefault()
      acceptGhostSuggestion(ghostSuggestion)
      return
    }

    if (ghostSuggestion && event.key === "Escape") {
      event.preventDefault()
      setDismissedSuggestion(ghostSuggestion)
      return
    }

    if (commandPaletteOpen && (event.key === "Tab" || event.key === "Enter")) {
      event.preventDefault()
      completeSlashCommand(matchingCommands[activeCommandIndex] || matchingCommands[0])
      return
    }

    if (commandPaletteOpen && event.key === "ArrowDown") {
      event.preventDefault()
      setActiveCommandIndex((current) => (current + 1) % matchingCommands.length)
      return
    }

    if (commandPaletteOpen && event.key === "ArrowUp") {
      event.preventDefault()
      setActiveCommandIndex((current) => (current - 1 + matchingCommands.length) % matchingCommands.length)
      return
    }

    if (commandPaletteOpen && event.key === "Escape") {
      event.preventDefault()
      setText("")
      return
    }

    if (event.key === "Tab" && !event.shiftKey && !event.altKey && !event.ctrlKey && !event.metaKey && text.trim().length > 0) {
      event.preventDefault()
      stash.mutate(undefined)
      return
    }

    if (!submitWithEnter || event.key !== "Enter" || event.shiftKey || event.nativeEvent.isComposing) return

    event.preventDefault()
    submitMessage()
  }

  function completeSlashCommand(command: SlashCommand) {
    const leadingWhitespace = text.match(/^\s*/)?.[0] || ""
    setText(`${leadingWhitespace}${command.name} `)
    setPendingConfirmation(null)
  }

  function updateText(nextText: string) {
    setText(nextText)
    if (pendingConfirmation && nextText.trim() !== pendingConfirmation.text) {
      setPendingConfirmation(null)
    }
  }

  useEffect(() => {
    setActiveCommandIndex(0)
  }, [commandQuery])

  useEffect(() => {
    if (activeCommandIndex >= matchingCommands.length) setActiveCommandIndex(0)
  }, [activeCommandIndex, matchingCommands.length])

  useEffect(() => {
    setJumpIndex(0)
  }, [pendingProposals.length])

  useEffect(() => {
    if (autoFocus) textareaRef.current?.focus()
  }, [autoFocus, payload.chat.id])

  // An Escape-dismissed suggestion stays dismissed for this chat view
  // only; switching chats starts fresh.
  useEffect(() => {
    setDismissedSuggestion(null)
  }, [payload.chat.id])

  // Track when the current suggestion arrived so Tab interception can
  // ignore suggestions younger than the grace period (see handleKeyDown).
  useEffect(() => {
    if (suggestedNextStep) suggestionShownAtRef.current = Date.now()
  }, [suggestedNextStep])

  useEffect(() => {
    const textarea = textareaRef.current
    if (!textarea) return

    autosizeChatTextarea(textarea)
  }, [text])

  useEffect(() => {
    function handleResize() {
      const textarea = textareaRef.current
      if (textarea) autosizeChatTextarea(textarea)
    }

    window.addEventListener("resize", handleResize)
    return () => window.removeEventListener("resize", handleResize)
  }, [])

  useEffect(() => {
    if (!attachmentPopoverOpen) return

    function handlePointerDown(event: PointerEvent) {
      const target = event.target as Node | null
      if (!target) return
      if (attachmentPopoverRef.current?.contains(target)) return
      if (addAttachmentButtonRef.current?.contains(target)) return

      setAttachmentPopoverOpen(false)
    }

    document.addEventListener("pointerdown", handlePointerDown)
    return () => document.removeEventListener("pointerdown", handlePointerDown)
  }, [attachmentPopoverOpen])

  useEffect(() => {
    if (!attachmentPopoverOpen) return

    const firstControl =
      attachmentPopoverRef.current?.querySelector<HTMLElement>("[data-autofocus]") ||
      attachmentPopoverRef.current?.querySelector<HTMLElement>("button:not(:disabled), input:not(:disabled), select:not(:disabled)")
    firstControl?.focus()
  }, [attachmentPopoverOpen])

  return (
    <>
      {pendingProposals.length > 0 ? (
        <div className="flex items-center justify-between rounded border border-amber-200 bg-amber-50 px-3 py-1.5 text-xs text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-300">
          <span>
            {pendingProposals.length === 1
              ? "1 pending proposal"
              : `${pendingProposals.length} pending proposals`}
          </span>
          <button
            className="font-medium underline hover:no-underline"
            onClick={jumpToPending}
            type="button"
          >
            {pendingProposals.length > 1 ? `Jump (${(jumpIndex % pendingProposals.length) + 1} of ${pendingProposals.length})` : "Jump ↑"}
          </button>
        </div>
      ) : null}
      {recorder.state.phase === "recording" && nativeRecorderHud && annotationIdleKind === "accessibility" ? (
        // The floating native HUD only fits the terse hint; the actionable
        // System Settings guidance renders here in the page — the ONLY way a
        // desktop user (always on the native HUD) ever sees it.
        <div className="rounded border border-amber-200 bg-amber-50 px-3 py-1.5 text-xs text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-300" data-testid="walkthrough-annotate-accessibility-note">
          {t("walkthrough_annotate_accessibility_note")}
        </div>
      ) : null}
      {recorder.state.phase === "recording" && !nativeRecorderHud ? (
        <WalkthroughRecorderHUD
          annotation={
            recorder.annotationAvailable
              ? {
                  // Mode-aware: HOLD reads "Hold ⌃ to draw", TAP reads "⌘⇧A to
                  // draw"; both swap to the drawing variant while the pen is
                  // armed.
                  hint: annotationHintIdle,
                  drawingHint: annotationHintDrawing,
                  drawing: recorder.drawing,
                  surfaceNote: shouldShowAnnotationSurfaceNote(recorder.annotationAvailable, recorder.displaySurface)
                    ? t("walkthrough_annotate_surface_note")
                    : undefined,
                  // In-page guidance for the no-accessibility degrade: name the
                  // System Settings pane that brings hold-to-draw back.
                  accessibilityNote:
                    annotationIdleKind === "accessibility" ? t("walkthrough_annotate_accessibility_note") : undefined
                }
              : undefined
          }
          elapsed={recorder.elapsed}
          labels={{
            recording: t("walkthrough_recording"),
            noMic: t("walkthrough_no_mic"),
            stop: t("walkthrough_stop"),
            discard: t("walkthrough_discard"),
            windowHint: t("walkthrough_window_hint"),
            remaining: (clock) => t("walkthrough_remaining", { clock })
          }}
          micLive={recorder.state.micLive}
          onDiscard={() => recorder.stop({ discard: true })}
          onStop={() => recorder.stop()}
        />
      ) : null}
      {geminiSheetOpen ? (
        <GeminiSetupSheet
          labels={{
            title: t("gemini_setup_title"),
            intro: t("gemini_setup_intro"),
            getKey: t("gemini_setup_get_key"),
            keyPlaceholder: t("gemini_setup_placeholder"),
            validateAndSave: t("gemini_setup_save"),
            validating: t("gemini_setup_validating"),
            stageFormat: t("gemini_stage_format"),
            stageReach: t("gemini_stage_reach"),
            stageVideo: t("gemini_stage_video"),
            saved: t("gemini_setup_saved"),
            keyHelp: t("gemini_setup_key_help")
          }}
          onClose={() => setGeminiSheetOpen(false)}
          onConfigured={() => {
            setGeminiSheetOpen(false)
            void queryClient.invalidateQueries({ queryKey })
            const pending = pendingVideoRef.current
            pendingVideoRef.current = null
            // assumeConfigured: the key was just saved, but this render's
            // payload.gemini_configured is still stale until the refetch
            // lands — without it, intake would re-open the sheet forever.
            if (pending) void intakeWalkthroughVideo(pending, { assumeConfigured: true })
          }}
        />
      ) : null}
      {reportDialogOpen ? (
        <ReportIssueDialog
          body={reportIssueBody(payload, prefix)}
          onClose={() => setReportDialogOpen(false)}
          onFiled={(issueUrl) => {
            onNotice(`Issue filed — ${issueUrl}`)
            setReportDialogOpen(false)
          }}
        />
      ) : null}
      <form
        className={`relative transition-shadow ${isDragOver ? "ring-2 ring-blue-400 dark:ring-blue-500" : ""}`}
        onDragEnter={handleDragEnter}
        onDragLeave={handleDragLeave}
        onDragOver={handleDragOver}
        onDrop={handleDrop}
        onSubmit={submit}
      >
        {send.isError ? <div className="mb-2 text-sm text-red-700 dark:text-red-300">{errorMessage(send.error, "Message failed.")}</div> : null}
        {systemAction.isError ? <div className="mb-2 text-sm text-red-700 dark:text-red-300">{errorMessage(systemAction.error, "Command failed.")}</div> : null}
        {attachmentError ? <div className="mb-2 text-sm text-red-700 dark:text-red-300">{attachmentError}</div> : null}
        {clearConfirmationOpen ? (
          <div className="mb-2 flex flex-wrap items-center justify-between gap-2 rounded border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-100">
            <span>{t("clear_confirm")}</span>
            <span className="flex gap-2">
              <button className={secondaryButton()} disabled={systemAction.isPending} onClick={() => systemAction.mutate({ kind: "clear" })} type="button">{t("clear")}</button>
              <button className={secondaryButton()} disabled={systemAction.isPending} onClick={() => setClearConfirmationOpen(false)} type="button">{t("cancel")}</button>
            </span>
          </div>
        ) : null}
        {queuedMessages.length > 0 ? <QueuedMessages chatId={chatId} messages={queuedMessages} queryKey={queryKey} /> : null}
        <ScratchpadPanel
          chatId={chatId}
          enqueuePath={payload.paths.app_enqueue_message_path}
          items={payload.scratchpad_items || []}
          open={scratchpadOpen || (agentActive && (payload.scratchpad_items || []).length > 0)}
          queryKey={queryKey}
          reorderPath={payload.paths.app_scratchpad_reorder_path}
          text={text}
          onDismiss={() => setScratchpadOpen(false)}
          onLoadToInput={updateText}
        />
        {pendingConfirmation ? (
          <SlashCommandConfirmation
            commandName={pendingConfirmation.commandName}
            disabled={send.isPending || systemCommandAction.isPending}
            text={pendingConfirmation.text}
            onCancel={cancelPendingSlashCommand}
            onConfirm={confirmPendingSlashCommand}
          />
        ) : null}
        {commandPaletteOpen ? (
          <SlashCommandPalette
            activeIndex={activeCommandIndex}
            commands={matchingCommands}
            context={{ chat: { pinned: payload.chat.pinned } }}
            query={commandQuery}
            onSelect={(command) => completeSlashCommand(command)}
          />
        ) : null}
        {attachments.length > 0 ? (
          <div className="mb-3 flex flex-wrap gap-2">
            {attachments.map((attachment, index) => (
              <div className="flex max-w-full items-center gap-2 rounded border border-gray-200 bg-gray-50 px-2 py-1 text-sm text-gray-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200" key={`${attachment.name}-${index}`}>
                {attachment.mimeType.startsWith("image/") ? (
                  <>
                    <button aria-label={`Annotate ${attachment.name}`} className="group relative rounded focus:outline-none focus:ring-2 focus:ring-blue-500" onClick={() => setAnnotatingIndex(index)} type="button">
                      <img alt="" className="h-8 w-8 rounded object-cover" src={attachment.dataUrl} />
                      <span aria-hidden="true" className="absolute inset-0 flex items-center justify-center rounded bg-black/55 text-white opacity-0 transition-opacity group-hover:opacity-100 group-focus-visible:opacity-100">
                        <PencilIcon className="h-4 w-4" />
                      </span>
                    </button>
                    {annotatingIndex === index ? (
                      <ImageAnnotationModal
                        dataUrl={attachment.dataUrl}
                        name={attachment.name}
                        onClose={() => setAnnotatingIndex(null)}
                        onDone={(annotatedDataUrl) => {
                          setAttachments((current) => current.map((item, attachmentIndex) => attachmentIndex === index ? { ...item, dataUrl: annotatedDataUrl, mimeType: "image/png" } : item))
                          setAnnotatingIndex(null)
                        }}
                      />
                    ) : null}
                  </>
                ) : (
                  <span aria-hidden="true" className="flex h-8 w-8 items-center justify-center rounded border border-gray-200 bg-white text-xs font-semibold text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300">PDF</span>
                )}
                <span className="max-w-48 truncate" title={attachment.name}>{attachment.name}</span>
                <button aria-label={`Remove ${attachment.name}`} className="rounded p-2 text-gray-500 hover:bg-gray-200 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-700 dark:hover:text-gray-100" onClick={() => removeAttachment(index)} type="button">
                  <CloseIcon className="h-3.5 w-3.5" />
                </button>
              </div>
            ))}
          </div>
        ) : null}
      {walkthrough ? (
        <div className="mb-3 flex w-full items-center gap-3 rounded border border-gray-200 bg-gray-50 px-3 py-2 text-sm dark:border-gray-700 dark:bg-gray-900" data-testid="walkthrough-chip">
          <span aria-hidden="true" className="text-base">🎬</span>
          <span className="min-w-0 flex-1 truncate text-gray-800 dark:text-gray-200">
            {walkthrough.filename}
            {walkthrough.durationSeconds ? <span className="ml-1 text-xs text-gray-500">({formatClock(walkthrough.durationSeconds)})</span> : null}
          </span>
          {walkthrough.status === "ready" ? <span className="text-xs text-gray-500">{t("walkthrough_ready")}</span> : null}
          {walkthrough.status === "uploading" ? (
            <span className="flex items-center gap-2 text-xs text-gray-600 dark:text-gray-300">
              {t("walkthrough_uploading", { percent: walkthrough.percent })}
              <span className="h-1.5 w-24 overflow-hidden rounded-full bg-gray-200 dark:bg-gray-700">
                <span className="block h-full rounded-full bg-terracotta-600 transition-all" style={{ width: `${walkthrough.percent}%` }} />
              </span>
            </span>
          ) : null}
          {walkthrough.status === "analyzing" ? (
            <span className="flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-300">
              <span className="inline-block h-3 w-3 animate-spin rounded-full border-2 border-terracotta-500 border-t-transparent" />
              <AnalyzingHint messages={walkthroughAnalyzingHints} />
            </span>
          ) : null}
          {walkthrough.status === "failed" ? (
            <span className="flex items-center gap-2 text-xs text-red-700 dark:text-red-300">
              <span className="max-w-64 truncate" title={walkthrough.error}>{walkthrough.error}</span>
              {walkthrough.id ? (
                <button className="font-medium underline hover:no-underline" onClick={retryWalkthroughAnalysis} type="button">
                  {t("walkthrough_retry")}
                </button>
              ) : null}
            </span>
          ) : null}
          {walkthrough.status === "ready" || walkthrough.status === "failed" ? (
            <button
              aria-label={t("walkthrough_remove")}
              className="rounded-full p-2 text-gray-400 hover:bg-gray-200 hover:text-gray-600 dark:hover:bg-gray-700"
              onClick={() => {
                setWalkthrough(null)
                // Clear any walkthrough-scoped error (e.g. one-at-a-time) so
                // it can't linger and disable the send button for the next
                // ordinary message.
                setAttachmentError(null)
              }}
              type="button"
            >
              <CloseIcon className="h-3.5 w-3.5" />
            </button>
          ) : null}
        </div>
      ) : null}
      {showAttachedRepositories && attachedRepositories.length > 0 ? (
        <div className="mb-3 flex w-full flex-wrap gap-2">
          {attachedRepositories.map((repository) => (
            <span className="flex min-h-[44px] max-w-full items-center gap-1 rounded-full border border-blue-200 bg-blue-50 px-2.5 text-sm text-blue-800 dark:border-blue-800 dark:bg-blue-950 dark:text-blue-200" key={repository.id}>
              <span className="truncate" title={repository.label}>{repository.label}</span>
              <button
                aria-label={`Detach repository ${repository.label}`}
                className="rounded-full p-2 text-blue-600 hover:bg-blue-100 hover:text-blue-900 disabled:text-blue-300 dark:text-blue-300 dark:hover:bg-blue-900 dark:hover:text-blue-100 dark:disabled:text-blue-700"
                disabled={detachRepository.isPending}
                onClick={() => detachRepository.mutate(repository.app_detach_path)}
                title={`Detach repository ${repository.label}`}
                type="button"
              >
                <CloseIcon className="h-3.5 w-3.5" />
              </button>
            </span>
          ))}
        </div>
      ) : null}
      <input
        accept={payload.walkthroughs_enabled ? "image/*,application/pdf,video/webm,video/mp4,video/quicktime" : "image/*,application/pdf"}
        aria-label={t("chat_attachments")}
        className="hidden"
        disabled={send.isPending || systemAction.isPending}
        multiple
        onChange={(event) => handleAttachmentChange(event.target.files)}
        ref={fileInputRef}
        type="file"
      />
      <div className="relative">
        <textarea
          aria-controls={commandPaletteOpen ? "chat-slash-command-palette" : undefined}
          aria-expanded={commandPaletteOpen}
          aria-haspopup="listbox"
          className={`min-h-9 w-full resize-none overflow-y-hidden rounded border border-gray-200 bg-white py-2 pl-3 ${textareaPr} text-base leading-6 focus:border-blue-500 focus:ring-blue-500 disabled:bg-gray-50 sm:text-sm sm:leading-5 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100 dark:placeholder:text-gray-500 dark:disabled:bg-gray-800`}
          disabled={send.isPending || systemAction.isPending}
          onChange={(event) => {
            updateText(event.target.value)
            if (clearConfirmationOpen) setClearConfirmationOpen(false)
          }}
          onKeyDown={handleKeyDown}
          onPaste={handlePaste}
          placeholder={ghostSuggestion ? "" : payload.switching_provider ? t("switching_to_provider", { provider: providerLabel(payload.chat.chat_provider ?? "") }) : agentActive ? t("queue_followup") : payload.chat.repository ? t("ask_repository") : t("ask_anything")}
          ref={textareaRef}
          required={attachments.length === 0 && walkthrough?.status !== "ready"}
          rows={1}
          value={text}
        />
        {ghostSuggestion ? (
          <div aria-hidden="true" className="pointer-events-none absolute inset-y-0 left-0 right-0 flex items-center gap-2 overflow-hidden px-3 py-2 text-base leading-6 sm:text-sm sm:leading-5" data-testid="chat-suggestion-ghost">
            <span className="truncate text-gray-400 dark:text-gray-500">{ghostSuggestion}</span>
            <span className="inline-flex shrink-0 items-center rounded border border-gray-300 bg-gray-50 px-1 text-[10px] font-medium text-gray-400 dark:border-gray-600 dark:bg-gray-800 dark:text-gray-500">⇥ {t("suggestion_tab_hint")}</span>
          </div>
        ) : null}
        <span aria-live="polite" className="sr-only">{ghostSuggestion ? t("suggestion_available", { suggestion: ghostSuggestion }) : ""}</span>
        <div className="absolute bottom-2 right-2 flex items-center gap-1">
          <button
            aria-label={agentActive ? t("enqueue_message") : t("send_message")}
            className="flex h-8 w-8 items-center justify-center rounded bg-blue-600 text-white hover:bg-blue-500 disabled:opacity-60 dark:bg-blue-500 dark:hover:bg-blue-400"
            disabled={send.isPending || systemAction.isPending || systemCommandAction.isPending || (text.trim().length === 0 && walkthrough?.status !== "ready" && attachments.length === 0) || pendingConfirmation != null || attachmentError != null}
            type="submit"
          >
            {agentActive ? <EnqueueIcon className="h-4 w-4" /> : <SendIcon className="h-4 w-4" />}
          </button>
          {text.trim().length > 0 ? (
            <button
              aria-label={t("scratchpad_stash")}
              className="flex h-8 w-8 items-center justify-center rounded border border-gray-300 bg-white text-gray-600 hover:bg-gray-50 disabled:text-gray-300 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-300 dark:hover:bg-gray-800 dark:disabled:text-gray-600"
              disabled={stash.isPending}
              onClick={() => stash.mutate(undefined)}
              title={agentActive ? t("scratchpad_stash") : t("scratchpad_stash_tab")}
              type="button"
            >
              <svg aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                <path d="M9 5H7a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-2" />
                <rect height="4" rx="1" width="6" x="9" y="3" />
                <path d="M9 12h6M9 16h4" />
              </svg>
            </button>
          ) : null}
          {agentActive && !payload.switching_provider ? (
            <StopButton
              className="flex h-8 w-8 items-center justify-center rounded border border-red-200 bg-white text-red-700 hover:bg-red-50 disabled:text-gray-400 dark:border-red-800 dark:bg-gray-900 dark:text-red-300 dark:hover:bg-red-950 dark:disabled:text-gray-600"
              payload={payload}
              queryKey={queryKey}
            />
          ) : null}
        </div>
      </div>
      <div className="relative flex items-center justify-between mt-2">
        <div className="flex items-center gap-2">
          <button
            aria-controls={attachmentPopoverOpen ? "chat-attachment-popover" : undefined}
            aria-expanded={attachmentPopoverOpen}
            aria-label={t("add_attachment")}
            aria-haspopup="dialog"
            className="flex h-6 w-6 shrink-0 items-center justify-center rounded border border-gray-300 bg-white text-sm leading-none text-gray-700 hover:bg-gray-50 disabled:text-gray-300 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-600"
            disabled={send.isPending || systemAction.isPending}
            onClick={() => setAttachmentPopoverOpen((open) => !open)}
            ref={addAttachmentButtonRef}
            type="button"
          >
            +
          </button>
          <ChatModeSelector chatId={chatId} payload={payload} queryKey={queryKey} />
          {(payload.chat.available_chat_models?.length ?? 0) > 0 ? (
            <select
              aria-label={t("aria_chat_model")}
              className="h-8 rounded border border-gray-300 bg-white px-2 py-0 text-xs text-gray-700 hover:bg-gray-50 disabled:text-gray-300 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-600"
              disabled={updateModel.isPending || agentActive}
              value={payload.chat.chat_model ?? ""}
              onChange={(event) => {
                const value = event.target.value || null
                updateModel.mutate(value)
              }}
            >
              <option value="">{t("chat_model_default")}</option>
              {payload.chat.available_chat_models!.map((model) => (
                <option key={model.value} value={model.value}>{model.label}</option>
              ))}
            </select>
          ) : null}
        </div>
        {attachmentPopoverOpen ? (
          <div
            aria-label={t("add_attachment")}
            className="absolute bottom-full left-0 z-20 w-[min(22rem,calc(100%-1.5rem))] overflow-hidden rounded border border-gray-200 bg-white shadow-lg dark:border-gray-700 dark:bg-gray-950"
            id="chat-attachment-popover"
            onKeyDown={handleAttachmentPopoverKeyDown}
            ref={attachmentPopoverRef}
            role="dialog"
          >
            <button
              className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"
              onClick={openAttachmentFilePicker}
              type="button"
            >
              <UploadIcon className="h-4 w-4 shrink-0 text-gray-400" />
              {t("upload_file")}
            </button>
            {payload.walkthroughs_enabled ? (
              <button
                className="flex w-full items-start gap-2 px-3 py-2 text-left text-sm text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"
                onClick={startWalkthroughRecording}
                title={t("record_walkthrough_title")}
                type="button"
              >
                <span aria-hidden="true" className="mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center">
                  <span className="h-2.5 w-2.5 rounded-full border-2 border-red-500" />
                </span>
                <span className="min-w-0">
                  <span className="block">{t("record_walkthrough")}</span>
                  <span className="mt-0.5 block text-xs text-gray-500 dark:text-gray-400">{t("record_walkthrough_hint")}</span>
                </span>
              </button>
            ) : null}
            <div className="border-t border-gray-100 dark:border-gray-800" />
            <button
              className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"
              onClick={() => {
                setAttachmentPopoverOpen(false)
                setScratchpadOpen((prev) => !prev)
              }}
              type="button"
            >
              <svg aria-hidden="true" className="h-4 w-4 shrink-0 text-gray-400" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                <path d="M9 5H7a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-2" />
                <rect height="4" rx="1" width="6" x="9" y="3" />
                <path d="M9 12h6M9 16h4" />
              </svg>
              {t("scratchpad_title")}
            </button>
            <div className="border-t border-gray-100 dark:border-gray-800" />
            <AddAttachment payload={payload} prefix={prefix} queryKey={queryKey} onAttached={() => setAttachmentPopoverOpen(false)} onNotice={onNotice} />
          </div>
        ) : null}
        <div />
      </div>
      </form>
    </>
  )
}

function ChatModeSelector({ chatId, payload, queryKey }: { chatId: string; payload: ChatPayload; queryKey: ChatQueryKey }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const [dropdownOpen, setDropdownOpen] = useState(false)
  const buttonRef = useRef<HTMLButtonElement | null>(null)
  const dropdownRef = useRef<HTMLDivElement | null>(null)

  const modeOptions: Array<{ value: ChatMode; label: string }> = [
    { value: "planning", label: t("mode_planning") },
    ...(payload.coding_mode_enabled ? [{ value: "coding" as ChatMode, label: t("mode_coding") }] : []),
    ...(payload.local_mode_enabled ? [{ value: "local" as ChatMode, label: t("mode_local") }] : [])
  ]

  const mode = useMutation({
    mutationFn: (value: ChatMode) => updateChatMode(chatId, value),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      updateRecentChatCache(queryClient, updated.chat)
    }
  })

  useEffect(() => {
    if (!dropdownOpen) return
    function handlePointerDown(event: PointerEvent) {
      const target = event.target as Node | null
      if (!target) return
      if (dropdownRef.current?.contains(target)) return
      if (buttonRef.current?.contains(target)) return
      setDropdownOpen(false)
    }
    document.addEventListener("pointerdown", handlePointerDown)
    return () => document.removeEventListener("pointerdown", handlePointerDown)
  }, [dropdownOpen])

  if (modeOptions.length <= 1) return null

  const currentMode = payload.chat.mode || "planning"
  const currentLabel = modeOptions.find((opt) => opt.value === currentMode)?.label ?? t("mode_planning")

  return (
    <div className="relative">
      <button
        aria-expanded={dropdownOpen}
        aria-haspopup="listbox"
        aria-label={t("mode_selector_label")}
        className="flex items-center gap-1 rounded border border-gray-300 bg-white px-2.5 py-1.5 text-sm text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800"
        disabled={mode.isPending}
        onClick={() => setDropdownOpen((open) => !open)}
        ref={buttonRef}
        type="button"
      >
        <span>{currentLabel}</span>
        <svg aria-hidden="true" className="h-3 w-3 shrink-0" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
          <path d="M6 9l6 6 6-6" />
        </svg>
      </button>
      {dropdownOpen ? (
        <div
          className="absolute bottom-full left-0 z-20 mb-1 min-w-[7rem] overflow-hidden rounded border border-gray-200 bg-white shadow-lg dark:border-gray-700 dark:bg-gray-950"
          ref={dropdownRef}
          role="listbox"
        >
          {modeOptions.map(({ value, label }) => (
            <button
              aria-selected={currentMode === value}
              className={`flex w-full items-center px-3 py-2 text-left text-sm ${
                currentMode === value
                  ? "bg-terracotta-50 font-medium text-terracotta-700 dark:bg-terracotta-950 dark:text-terracotta-200"
                  : "text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"
              }`}
              key={value}
              onClick={() => {
                mode.mutate(value)
                setDropdownOpen(false)
              }}
              role="option"
              type="button"
            >
              {label}
            </button>
          ))}
        </div>
      ) : mode.isError ? (
        <div className="absolute bottom-full left-0 z-20 mb-1 whitespace-nowrap rounded border border-red-200 bg-white px-2 py-1 text-xs text-red-700 dark:border-red-800 dark:bg-gray-950 dark:text-red-300">
          {t("mode_update_error")}
        </div>
      ) : null}
    </div>
  )
}

function ReportIssueDialog({ body, onClose, onFiled }: { body: string; onClose: () => void; onFiled: (issueUrl: string) => void }) {
  const { t } = useT("chat")
  const [title, setTitle] = useState("")
  const [issueBody, setIssueBody] = useState(body)
  const report = useMutation({
    mutationFn: () => createReportIssue({ title, body: issueBody }),
    onSuccess: (result) => onFiled(result.issue_url)
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (title.trim().length === 0 || report.isPending) return

    report.mutate()
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-4" role="presentation">
      <form aria-label={t("aria_report_dialog")} aria-modal="true" className="w-full max-w-lg rounded border border-gray-200 bg-white p-4 shadow-xl dark:border-gray-700 dark:bg-gray-950" onSubmit={submit} role="dialog">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">{t("report_heading")}</h2>
          </div>
          <button aria-label={t("aria_close_report")} className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-100" disabled={report.isPending} onClick={onClose} type="button">
            <CloseIcon className="h-4 w-4" />
          </button>
        </div>
        <label className="mt-4 block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="report-issue-title">{t("field_title")}</label>
        <input
          autoFocus
          className="mt-1 w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
          disabled={report.isPending}
          id="report-issue-title"
          onChange={(event) => setTitle(event.target.value)}
          required
          type="text"
          value={title}
        />
        <label className="mt-3 block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="report-issue-body">{t("field_body")}</label>
        <textarea
          className="mt-1 h-40 w-full resize-y rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
          disabled={report.isPending}
          id="report-issue-body"
          onChange={(event) => setIssueBody(event.target.value)}
          value={issueBody}
        />
        {report.isError ? <p className="mt-3 text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(report.error, "Issue could not be filed.")}</p> : null}
        <div className="mt-4 flex justify-end gap-2">
          <button className={secondaryButton()} disabled={report.isPending} onClick={onClose} type="button">{t("cancel")}</button>
          <button className={primaryButton()} disabled={report.isPending || title.trim().length === 0} type="submit">{t("submit")}</button>
        </div>
      </form>
    </div>
  )
}

function reportIssueBody(payload: ChatPayload, prefix: string) {
  const path = withRoutePrefix(payload.chat.chat_path, prefix)
  const url = typeof window === "undefined" ? path : new URL(path, window.location.origin).toString()

  return `Context:\n- Chat: ${chatDisplayTitle(payload.chat)}\n- URL: ${url}\n\n`
}

function readAttachmentFile(file: File): Promise<ChatComposeAttachment> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => {
      resolve({
        name: file.name,
        mimeType: file.type || "application/octet-stream",
        dataUrl: String(reader.result || ""),
        size: file.size
      })
    }
    reader.onerror = () => reject(reader.error)
    reader.readAsDataURL(file)
  })
}

function SlashCommandConfirmation({ commandName, disabled, text, onCancel, onConfirm }: { commandName: SlashCommand["name"]; disabled: boolean; text: string; onCancel: () => void; onConfirm: () => void }) {
  const { t } = useT("chat")
  return (
    <div className="mb-3 rounded border border-amber-200 bg-amber-50 p-3 dark:border-amber-900 dark:bg-amber-950/40">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="min-w-0">
          <div className="text-xs font-semibold uppercase tracking-wide text-amber-700 dark:text-amber-300">Confirm {commandName}</div>
          <div className="mt-1 break-words font-mono text-sm text-gray-900 dark:text-gray-100">{text}</div>
        </div>
        <div className="flex shrink-0 gap-2">
          <button className={secondaryButton()} disabled={disabled} onClick={onCancel} type="button">{t("cancel")}</button>
          <button className={primaryButton()} disabled={disabled} onClick={onConfirm} type="button">{t("confirm")}</button>
        </div>
      </div>
    </div>
  )
}

function SlashCommandPalette({ activeIndex, commands, context, query, onSelect }: { activeIndex: number; commands: SlashCommand[]; context: { chat: { pinned?: boolean } }; query: string; onSelect: (command: SlashCommand) => void }) {
  const { t } = useT("chat")
  return (
    <div
      aria-label={t("aria_slash_commands")}
      className="absolute bottom-full left-3 right-3 z-10 mb-2 max-h-[calc(var(--chat-visual-viewport-height,100dvh)-9rem)] overflow-y-auto rounded border border-gray-200 bg-white shadow-lg overscroll-contain dark:border-gray-700 dark:bg-gray-950"
      id="chat-slash-command-palette"
      role="listbox"
    >
      {commands.map((command, index) => {
        const signature = slashCommandSignature(command)
        const active = index === activeIndex

        return (
          <button
            aria-selected={active}
            className={`flex w-full items-start gap-3 px-3 py-2 text-left text-sm ${active ? "bg-blue-50 dark:bg-blue-950" : "hover:bg-gray-50 dark:hover:bg-gray-900"}`}
            key={command.name}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => onSelect(command)}
            role="option"
            type="button"
          >
            <span className="min-w-0 flex-1">
              <span className="flex flex-wrap items-baseline gap-x-2">
                <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{highlightSlashCommand(command.name, query)}</span>
                {signature.length > 0 ? <span className="font-mono text-xs text-gray-500 dark:text-gray-400">{signature}</span> : null}
              </span>
              <span className="mt-0.5 block text-xs text-gray-500 dark:text-gray-400">{slashCommandDescription(command, context)}</span>
            </span>
            <span className={`shrink-0 rounded px-1.5 py-0.5 text-[0.65rem] font-semibold uppercase ${command.kind === "system" ? "bg-cyan-50 text-cyan-700 dark:bg-cyan-950 dark:text-cyan-200" : "bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-200"}`}>{command.kind}</span>
          </button>
        )
      })}
    </div>
  )
}

function highlightSlashCommand(name: string, query: string) {
  if (query.length === 0) return name

  const start = name.slice(1).toLowerCase().indexOf(query)
  if (start < 0) return name

  const from = start + 1
  const to = from + query.length
  return (
    <>
      {name.slice(0, from)}
      <mark className="bg-yellow-200 px-0 dark:bg-yellow-700 dark:text-gray-950">{name.slice(from, to)}</mark>
      {name.slice(to)}
    </>
  )
}

function QueuedMessages({ chatId, messages, queryKey }: { chatId: string; messages: ChatQueuedMessage[]; queryKey: ChatQueryKey }) {
  const { t } = useT("chat")
  return (
    <div className="mb-3 space-y-2 border-b border-gray-100 pb-3 dark:border-gray-800">
      <div className="text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">{t("queued_messages")}</div>
      {messages.map((message, index) => <QueuedMessageRow chatId={chatId} key={message.id} message={message} position={index + 1} queryKey={queryKey} />)}
    </div>
  )
}

function QueuedMessageRow({ chatId, message, position, queryKey }: { chatId: string; message: ChatQueuedMessage; position: number; queryKey: ChatQueryKey }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(message.text)
  const update = useMutation({
    mutationFn: () => updateQueuedChatMessage(appendSearch(message.app_update_path, search), draft),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setEditing(false)
    }
  })
  const remove = useMutation({
    mutationFn: () => deleteQueuedChatMessage(appendSearch(message.app_delete_path, search)),
    onSuccess: (updated) => queryClient.setQueryData(queryKey, updated)
  })
  const stash = useMutation({
    mutationFn: async () => {
      const afterCreate = await createScratchpadItem(chatId, message.text)
      queryClient.setQueryData(queryKey, afterCreate)
      return deleteQueuedChatMessage(appendSearch(message.app_delete_path, search))
    },
    onSuccess: (updated) => queryClient.setQueryData(queryKey, updated)
  })

  useEffect(() => {
    if (!editing) setDraft(message.text)
  }, [editing, message.text])

  if (editing) {
    return (
      <div className="rounded border border-blue-200 bg-blue-50 p-2 dark:border-blue-800 dark:bg-blue-950">
        {update.isError ? <div className="mb-2 text-xs text-red-700 dark:text-red-300">{errorMessage(update.error, "Queued message could not be updated.")}</div> : null}
        <textarea
          aria-label={`Edit queued message ${position}`}
          className="min-h-16 w-full resize-y rounded border border-blue-200 bg-white px-2 py-1.5 text-sm focus:border-blue-500 focus:ring-blue-500 dark:border-blue-800 dark:bg-gray-950 dark:text-gray-100"
          onChange={(event) => setDraft(event.target.value)}
          value={draft}
        />
        <div className="mt-2 flex justify-end gap-2">
          <button className="rounded border border-gray-300 bg-white px-2.5 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800" disabled={update.isPending} onClick={() => setEditing(false)} type="button">{t("cancel")}</button>
          <button className="rounded bg-blue-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-blue-700 disabled:bg-blue-300 dark:hover:bg-blue-500 dark:disabled:bg-gray-700" disabled={update.isPending || draft.trim().length === 0} onClick={() => update.mutate()} type="button">{t("save")}</button>
        </div>
      </div>
    )
  }

  return (
    <div>
      <div className="flex items-start gap-2 rounded border border-gray-200 bg-gray-50 px-2 py-1.5 dark:border-gray-700 dark:bg-gray-800">
        <span className="mt-0.5 shrink-0 text-xs font-medium text-gray-500 dark:text-gray-400">{position}</span>
        <button className="min-w-0 flex-1 text-left text-sm text-gray-700 hover:text-blue-700 dark:text-gray-200 dark:hover:text-blue-300" onClick={() => setEditing(true)} type="button">
          <span className="line-clamp-2 whitespace-pre-wrap break-words">{message.text}</span>
        </button>
        <button
          aria-label={t("scratchpad_stash")}
          className="rounded p-2 text-gray-400 hover:bg-white hover:text-blue-600 disabled:text-gray-300 dark:text-gray-500 dark:hover:bg-gray-700 dark:hover:text-blue-300 dark:disabled:text-gray-700"
          disabled={stash.isPending || remove.isPending}
          onClick={() => stash.mutate()}
          title={t("scratchpad_stash")}
          type="button"
        >
          <svg aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
            <path d="M9 5H7a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-2" />
            <rect height="4" rx="1" width="6" x="9" y="3" />
            <path d="M9 12h6M9 16h4" />
          </svg>
        </button>
        <button
          aria-label={`Delete queued message ${position}`}
          className="rounded p-2 text-gray-400 hover:bg-white hover:text-red-600 disabled:text-gray-300 dark:text-gray-500 dark:hover:bg-gray-700 dark:hover:text-red-300 dark:disabled:text-gray-700"
          disabled={remove.isPending || stash.isPending}
          onClick={() => remove.mutate()}
          type="button"
        >
          <CloseIcon className="h-4 w-4" />
        </button>
      </div>
      {stash.isError ? <div className="mt-0.5 text-xs text-red-700 dark:text-red-300">{errorMessage(stash.error, "Could not move to scratch pad.")}</div> : null}
    </div>
  )
}

function autosizeChatTextarea(textarea: HTMLTextAreaElement) {
  textarea.style.height = "auto"

  const style = window.getComputedStyle(textarea)
  const lineHeight = parsePixelValue(style.lineHeight) || 20
  const verticalPadding = parsePixelValue(style.paddingTop) + parsePixelValue(style.paddingBottom)
  const verticalBorder = parsePixelValue(style.borderTopWidth) + parsePixelValue(style.borderBottomWidth)
  const minHeight = lineHeight + verticalPadding + verticalBorder
  const maxHeight = (lineHeight * CHAT_COMPOSE_MAX_ROWS) + verticalPadding + verticalBorder
  const nextHeight = Math.min(Math.max(textarea.scrollHeight, minHeight), maxHeight)

  textarea.style.height = `${nextHeight}px`
  textarea.style.overflowY = textarea.scrollHeight > maxHeight ? "auto" : "hidden"
}

function useSubmitChatWithEnter() {
  const [enabled, setEnabled] = useState(isDesktopChatViewport)

  useEffect(() => {
    const update = () => setEnabled(isDesktopChatViewport())
    update()
    window.addEventListener("resize", update)
    return () => window.removeEventListener("resize", update)
  }, [])

  return enabled
}

function StopButton({ className, payload, queryKey }: { className?: string; payload: ChatPayload; queryKey: ChatQueryKey }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const stop = useMutation({
    mutationFn: () => stopChat(appendSearch(payload.paths.app_stop_path, search)),
    onSuccess: (updated) => queryClient.setQueryData(queryKey, updated)
  })
  return (
    <button aria-label={t("aria_stop_agent")} className={className ?? "inline-flex h-11 items-center justify-center rounded border border-red-200 bg-white px-3 text-sm font-medium text-red-700 hover:bg-red-50 disabled:text-gray-400 dark:border-red-800 dark:bg-gray-900 dark:text-red-300 dark:hover:bg-red-950 dark:disabled:text-gray-600"} disabled={Boolean(payload.chat.stop_requested_at) || stop.isPending} onClick={() => stop.mutate()} type="button">
      <StopIcon className={`h-4 w-4 ${payload.chat.stop_requested_at || stop.isPending ? "opacity-50" : ""}`} />
    </button>
  )
}

function findProposalBySlug(payload: ChatPayload, slug: string): { app_reject_path: string } | null {
  const normalized = slug.trim().toLowerCase()
  if (!normalized) return null

  for (const message of payload.messages) {
    const proposal = message.proposal
    if (!proposal) continue
    if (proposal.slug.toLowerCase() === normalized) return proposal

    const child = proposal.children?.find((item) => item.slug.toLowerCase() === normalized)
    if (child) return child
  }

  return null
}

function scrollToLastProposalCard() {
  const messages = Array.from(document.querySelectorAll<HTMLElement>('[id^="chat_message_"]'))
  const target = messages.filter((message) => message.querySelector("[data-proposal-card]")).at(-1)
  if (!target) return false

  target.scrollIntoView({ behavior: "smooth", block: "start" })
  return true
}
