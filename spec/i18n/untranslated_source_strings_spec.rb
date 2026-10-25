require "rails_helper"
require "set"
require "tempfile"

RSpec.describe "Untranslated source strings", type: :unit do
  CHAT_I18N_DEBT_FILES = %w[
    app/frontend/routes/chat/streamBuilders.ts
    app/frontend/routes/chat/streamChrome.tsx
    app/frontend/routes/chat/tool_cards/create_tag.tsx
    app/frontend/routes/chat/tool_cards/daemon_ping.tsx
    app/frontend/routes/chat/tool_cards/mark_goal_blocked.tsx
    app/frontend/routes/chat/tool_cards/mark_goal_completed.tsx
    app/frontend/routes/chat/tool_cards/submit_artifact.tsx
    app/frontend/routes/chat/tool_cards/write_file.tsx
  ].freeze

  CHAT_I18N_REVIEWED_FILES = %w[
    app/frontend/routes/chat/tool_cards/admin_cleanup_workspace.tsx
    app/frontend/routes/chat/tool_cards/admin_github_app_installation_diagnostic.tsx
    app/frontend/routes/chat/tool_cards/admin_kill_process.tsx
    app/frontend/routes/chat/tool_cards/admin_list_processes.tsx
    app/frontend/routes/chat/tool_cards/admin_list_runs.tsx
    app/frontend/routes/chat/tool_cards/admin_list_users.tsx
    app/frontend/routes/chat/tool_cards/admin_maintenance_tasks.tsx
    app/frontend/routes/chat/tool_cards/admin_mcp_tool_usage.tsx
    app/frontend/routes/chat/tool_cards/admin_overview.tsx
    app/frontend/routes/chat/tool_cards/admin_pause_runs.tsx
    app/frontend/routes/chat/tool_cards/admin_pause_user_scheduling.tsx
    app/frontend/routes/chat/tool_cards/admin_read_operational_logs.tsx
    app/frontend/routes/chat/tool_cards/admin_retry_step.tsx
    app/frontend/routes/chat/tool_cards/admin_stuck_jobs.tsx
    app/frontend/routes/chat/tool_cards/admin_unpause_user_scheduling.tsx
    app/frontend/routes/chat/tool_cards/admin_version.tsx
    app/frontend/routes/chat/tool_cards/adopt_current_pr_head.tsx
    app/frontend/routes/chat/tool_cards/classify_pull_request.tsx
    app/frontend/routes/chat/tool_cards/clear_provider_circuit.tsx
    app/frontend/routes/chat/tool_cards/dispatch_ref_movement_action.tsx
    app/frontend/routes/chat/tool_cards/emergency_land.tsx
    app/frontend/routes/chat/tool_cards/force_landing_recheck.tsx
    app/frontend/routes/chat/tool_cards/ingest_pull_request.tsx
    app/frontend/routes/chat/tool_cards/mark_ci_repair_noop.tsx
    app/frontend/routes/chat/tool_cards/pause_landing_queue.tsx
    app/frontend/routes/chat/tool_cards/run_command.tsx
    app/frontend/routes/chat/tool_cards/wake_provider_admission.tsx
    app/frontend/routes/chat/tool_cards/add_epic_dependency.tsx
    app/frontend/routes/chat/tool_cards/add_job_tag.tsx
    app/frontend/routes/chat/tool_cards/remove_job_tag.tsx
    app/frontend/routes/chat/tool_cards/force_state_transition.tsx
    app/frontend/routes/chat/tool_cards/reopen_job.tsx
    app/frontend/routes/chat/tool_cards/delegate_issue.tsx
    app/frontend/routes/chat/tool_cards/select_job_delivery_track.tsx
    app/frontend/routes/chat/tool_cards/create_coding_job.tsx
    app/frontend/routes/chat/tool_cards/open_in_coding_mode.tsx
    app/frontend/routes/chat/tool_cards/open_in_local_mode.tsx
    app/frontend/routes/chat/tool_cards/cancel_coding_checkout.tsx
    app/frontend/routes/chat/tool_cards/cancel_local_mode.tsx
    app/frontend/routes/chat/tool_cards/submit_coding_changes.tsx
    app/frontend/routes/chat/tool_cards/submit_chat_feedback.tsx
    app/frontend/routes/chat/tool_cards/update_pinned_context.tsx
    app/frontend/routes/chat/tool_cards/remove_pinned_context.tsx
    app/frontend/routes/chat/tool_cards/propose_job.tsx
    app/frontend/routes/chat/tool_cards/propose_epic.tsx
    app/frontend/routes/chat/tool_cards/propose_epic_with_jobs.tsx
    app/frontend/routes/chat/tool_cards/ask_user_question.tsx
    app/frontend/routes/chat/tool_cards/send_chat_message.tsx
    app/frontend/routes/chat/tool_cards/spawn_chats.tsx
    app/frontend/routes/chat/tool_cards/set_bookmark.tsx
    app/frontend/routes/chat/tool_cards/suggest_next_step.tsx
    app/frontend/routes/chat/tool_cards/attach_repository.tsx
    app/frontend/routes/chat/tool_cards/detach_repository.tsx
    app/frontend/routes/chat/tool_cards/create_repo_document.tsx
    app/frontend/routes/chat/tool_cards/delete_repo_document.tsx
    app/frontend/routes/chat/tool_cards/rename_chat.tsx
    app/frontend/routes/chat/tool_cards/schedule_wakeup.tsx
    app/frontend/routes/chat/tool_cards/cancel_wakeup.tsx
    app/frontend/routes/chat/Compose.tsx
    app/frontend/routes/chat/AgentQuestions.tsx
    app/frontend/routes/chat/ParticipantPicker.tsx
    app/frontend/routes/chat/JobEpicPickerPopup.tsx
    app/frontend/routes/chat/ScheduleMessageModal.tsx
    app/frontend/routes/chat/WorkspacePanels.tsx
    app/frontend/routes/chat/ProposalCards.tsx
    app/frontend/routes/chat/ScratchpadPanel.tsx
    app/frontend/routes/chat/proposalDisplay.ts
    app/frontend/routes/chat/proposalToolCard.tsx
    app/frontend/routes/chat/repoDocumentToolCard.tsx
    app/frontend/routes/chat/pinnedContextToolCard.tsx
    app/frontend/routes/chat/chatPinToolCard.tsx
    app/frontend/routes/chat/chatSearchToolCard.tsx
    app/frontend/routes/chat/chatHelperToolCard.tsx
    app/frontend/routes/chat/adminToolCard.tsx
    app/frontend/routes/chat/issueTagArtifactToolCard.tsx
    app/frontend/routes/chat/jobEpicMaintenanceToolCard.tsx
    app/frontend/routes/chat/pendingActionToolCard.tsx
    app/frontend/routes/chat/refMovementToolCard.tsx
    app/frontend/routes/chat/runtimeToolCard.tsx
    app/frontend/routes/chat/tool_cards/admin_queue_detail.tsx
    app/frontend/routes/chat/tool_cards/force_rebase.tsx
    app/frontend/routes/chat/tool_cards/inspect_provider_circuit.tsx
    app/frontend/routes/chat/tool_cards/override_landing_blocker_once.tsx
    app/frontend/routes/chat/tool_cards/read_worker_health.tsx
    app/frontend/routes/chat/tool_cards/reconcile_job_state.tsx
    app/frontend/routes/chat/tool_cards/reenqueue_work.tsx
    app/frontend/routes/chat/tool_cards/refresh_pr_checks.tsx
    app/frontend/routes/chat/tool_cards/repair_provider_circuit_evidence.tsx
    app/frontend/routes/chat/tool_cards/resolve_delivery_policy.tsx
    app/frontend/routes/chat/tool_cards/read_job.tsx
    app/frontend/routes/chat/tool_cards/read_epic.tsx
    app/frontend/routes/chat/tool_cards/read_pr.tsx
    app/frontend/routes/chat/tool_cards/read_workflow.tsx
    app/frontend/routes/chat/tool_cards/read_run_transcript.tsx
    app/frontend/routes/chat/tool_cards/read_artifact.tsx
    app/frontend/routes/chat/tool_cards/read_file.tsx
    app/frontend/routes/chat/tool_cards/read_queue.tsx
    app/frontend/routes/chat/tool_cards/read_ref_movement_status.tsx
    app/frontend/routes/chat/tool_cards/repo_info.tsx
    app/frontend/routes/chat/tool_cards/get_job_diff.tsx
    app/frontend/routes/chat/tool_cards/git_diff.tsx
    app/frontend/routes/chat/tool_cards/git_status.tsx
    app/frontend/routes/chat/tool_cards/list_job_workflows.tsx
    app/frontend/routes/chat/tool_cards/explain_stuck_job.tsx
  ].freeze

  # Run with:
  #   BUNDLE_PATH="$PWD/vendor/bundle" BUNDLE_APP_CONFIG="$PWD/.bundle" bundle exec rspec spec/i18n
  #
  # This is a deliberately conservative audit for obvious user-visible string
  # literals. It ignores tests, logs, routes, code-like tokens, and existing
  # localized surfaces. Allowlist entries below are intentionally narrow and
  # reserved for non-user-visible diagnostics, product/provider names,
  # protocol/code tokens, fixtures, and unavoidable dynamic/code-like fragments.

  def source_globs
    %w[
      app/frontend/**/*.{ts,tsx,js,jsx}
      app/views/**/*.erb
      plugins/*/app/frontend/**/*.{ts,tsx,js,jsx}
      desktop/src/**/*.{ts,tsx,js,jsx}
      website/src/**/*.{ts,tsx,js,jsx}
    ]
  end

  def excluded_path_patterns
    [
      %r{/spec/},
      %r{\.test\.[tj]sx?$},
      %r{/i18n/locales/},
      %r{desktop/src/i18n\.ts$},
      %r{app/frontend/pluginWorkspaceTabs\.tsx$},
      %r{app/frontend/routes/DesignSystem\.tsx$}
    ]
  end

  # Operator diagnostic renderers intentionally preserve terse English labels
  # that mirror MCP/tool payload keys, stack/runtime vocabulary, log output, or
  # desktop shell status. These surfaces are not product navigation or general
  # user-facing copy; broad legacy app/plugin UI path exemptions are not
  # allowed back into the audit.
  def internal_diagnostic_path_patterns
    [
      %r{app/frontend/routes/jobDetail/WorkflowGraph\.tsx$},
      %r{desktop/src/App\.tsx$},
      %r{plugins/admin_mysql/app/frontend/adminMysqlToolCard\.tsx$},
      %r{plugins/agent_insights/app/frontend/agentInsightToolCard\.tsx$},
      %r{plugins/browser/app/frontend/browserToolCard\.tsx$},
      %r{plugins/github_source/app/frontend/routes/AdminGithubApiUsage\.tsx$},
      %r{plugins/theming_tools/app/frontend/themeToolCard\.tsx$},
      %r{plugins/video_walkthroughs/app/frontend/(?:tool_cards/.*|videoWalkthroughAnalysisToolCard)\.tsx$}
    ]
  end

  def code_or_protocol_literals
    @code_or_protocol_literals ||= <<~LITERALS.lines.map(&:strip).reject(&:blank?).to_set
      app/frontend/api/repositories.ts|jsx_text|githubSelectorFallback
      app/frontend/components/CoverageCard.tsx|jsx_text|(threshold: %)
      app/frontend/components/AdminEventActions.tsx|jsx_text|JOB-
      app/frontend/components/Checkbox.tsx|jsx_text|in a
      app/frontend/components/ShortcutsHelpModal.tsx|jsx_text|(items: T[]): ShortcutGroupSummary
      app/frontend/components/ui/Text.tsx|jsx_text|, keyof TextOwnProps
      app/frontend/components/FilePreviewModal.tsx|jsx_text|cursor) parts.push(
      app/frontend/routes/AdminBackendExceptions.tsx|jsx_text|active job
      app/frontend/routes/AdminMcpToolUsage.tsx|jsx_text|· ·
      app/frontend/routes/AdminReconcilerActivity.tsx|jsx_text|Run #
      app/frontend/routes/AdminUsers.tsx|jsx_text|[`#$`, job.state, job.kind,
      app/frontend/routes/AdminUsers.tsx|jsx_text|[`#$`, run.state, run.trigger_kind,
      app/frontend/routes/AdminWorkflowActivity.tsx|jsx_text|Run #
      app/frontend/routes/AdminWorkUnits.tsx|jsx_text|WI-
      app/frontend/routes/AdminWorkUnits.tsx|jsx_text|WU-
      app/frontend/routes/AppChromeV2.tsx|jsx_text|queryClient.getQueryData
      app/frontend/routes/appChromeV2/sidebarNav.tsx|jsx_text|"/dashboard/jobs", icon:
      app/frontend/routes/appChromeV2/sidebarNav.tsx|jsx_text|"/repositories", icon:
      app/frontend/routes/EpicDetail.tsx|jsx_text|· Goal #
      app/frontend/routes/JobDetail.tsx|jsx_text|( )
      app/frontend/routes/JobDetail.tsx|jsx_text|· Goal #
      app/frontend/routes/chat/MessageCards.tsx|ternary|md:pointer-events-auto md:opacity-100
      app/frontend/routes/chat/MessageCards.tsx|ternary|md:pointer-events-none md:opacity-0
      app/frontend/routes/chat/MessageCards.tsx|ternary|max-w-[calc(100vw-5rem)]
      app/frontend/routes/chat/MessageCards.tsx|ternary|max-w-[calc(100vw-2rem)]
      app/frontend/routes/chat/MessageCards.tsx|ternary|px-3 py-2
      app/frontend/routes/chat/MessageCards.tsx|jsx_text|(, )
      app/frontend/routes/chat/Compose.tsx|ternary|bg-brand/10 font-medium text-brand
      app/frontend/routes/chat/Compose.tsx|ternary|text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800
      app/frontend/routes/chat/JobEpicPickerPopup.tsx|user_visible_property|JOB-
      app/frontend/routes/chat/JobEpicPickerPopup.tsx|user_visible_property|EPIC-
      app/frontend/routes/chat/ProposalCards.tsx|user_visible_property|JOB-
      app/frontend/routes/chat/ProposalCards.tsx|user_visible_property|EPIC-
      app/frontend/routes/chat/ProposalCards.tsx|jsx_expression|#message-
      app/frontend/routes/chat/ProposalCards.tsx|jsx_expression|EPIC-
      app/frontend/routes/chat/ProposalCards.tsx|jsx_expression|JOB-
      app/frontend/routes/chat/issueTagArtifactToolCard.tsx|ternary|tag #
      app/frontend/routes/chat/tool_cards/force_rebase.tsx|ternary|JOB- ()
      app/frontend/routes/chat/tool_cards/force_rebase.tsx|ternary|JOB-
      app/frontend/routes/chat/tool_cards/refresh_pr_checks.tsx|ternary|JOB- ()
      app/frontend/routes/chat/tool_cards/refresh_pr_checks.tsx|ternary|JOB-
      app/frontend/routes/chat/tool_cards/refresh_pr_checks.tsx|jsx_expression|JOB-
      app/frontend/routes/chat/tool_cards/adopt_current_pr_head.tsx|user_visible_property|The requested workflow does not use an eligible base.
      app/frontend/routes/chat/tool_cards/emergency_land.tsx|user_visible_property|Emergency land requires operator confirmation.
      app/frontend/routes/chat/tool_cards/force_landing_recheck.tsx|user_visible_property|Force landing recheck
      app/frontend/routes/chat/tool_cards/force_landing_recheck.tsx|user_visible_property|One or more Jobs could not be rechecked.
      app/frontend/routes/chat/tool_cards/ingest_pull_request.tsx|ternary|JOB-
      app/frontend/routes/chat/tool_cards/ingest_pull_request.tsx|ternary|PR #
      app/frontend/routes/chat/tool_cards/mark_ci_repair_noop.tsx|user_visible_property|Workflow is not a CI failure repair. See https://ci.example.test/help/repair-workflows.
      app/frontend/routes/chat/tool_cards/admin_maintenance_tasks.tsx|jsx_text|Event #
      app/frontend/routes/chat/tool_cards/admin_stuck_jobs.tsx|ternary|JOB- —
      app/frontend/routes/chat/tool_cards/admin_stuck_jobs.tsx|ternary|JOB-
      app/frontend/routes/chat/tool_cards/pause_landing_queue.tsx|user_visible_property|Pause landing queue
      app/frontend/routes/chat/tool_cards/ask_user_question.tsx|user_visible_property|Waiting on the operator to answer in chat.
      app/frontend/routes/chat/tool_cards/ask_user_question.tsx|user_visible_property|result_error true -- renders through the shared ToolFailureSummaryCard instead of the waiting-state card.
      app/frontend/routes/chat/tool_cards/cancel_coding_checkout.tsx|user_visible_property|JOB-4225 was detached from this Coding Mode chat. No code changes were preserved or applied by this operation.
      app/frontend/routes/chat/tool_cards/cancel_coding_checkout.tsx|user_visible_property|Coding Mode checkout canceled for this chat. No code changes were preserved or applied by this operation.
      app/frontend/routes/chat/tool_cards/cancel_local_mode.tsx|user_visible_property|JOB-42 returned to
      app/frontend/routes/chat/tool_cards/cancel_local_mode.tsx|user_visible_property|JOB-43 was
      app/frontend/routes/chat/tool_cards/create_coding_job.tsx|user_visible_property|Improve repository search
      app/frontend/routes/chat/tool_cards/create_coding_job.tsx|user_visible_property|Created **JOB-7589** and queued it for implementation.
      app/frontend/routes/chat/tool_cards/open_in_coding_mode.tsx|user_visible_property|JOB-4225 is now open in Coding Mode on checkout branch
      app/frontend/routes/chat/tool_cards/open_in_local_mode.tsx|user_visible_property|JOB-4225 is now open for local implementation on branch
      app/frontend/routes/chat/tool_cards/remove_pinned_context.tsx|user_visible_property|Pinned context removed.
      app/frontend/routes/chat/tool_cards/submit_coding_changes.tsx|user_visible_property|Add dark mode
      app/frontend/routes/chat/tool_cards/submit_coding_changes.tsx|user_visible_property|Adds **theme controls** and documents the [setting](/settings).
      app/frontend/routes/chat/tool_cards/submit_coding_changes.tsx|user_visible_property|Pending **operator confirmation**.
      app/frontend/routes/chat/tool_cards/submit_coding_changes.tsx|user_visible_property|Adds theme controls.
      app/frontend/routes/chat/tool_cards/submit_coding_changes.tsx|user_visible_property|Submit coding changes was auto-confirmed by the active goal policy.
      app/frontend/routes/chat/tool_cards/submit_coding_changes.tsx|user_visible_property|Invalid submission
      app/frontend/routes/chat/tool_cards/submit_coding_changes.tsx|user_visible_property|Branch must contain committed changes.
      app/frontend/routes/chat/tool_cards/update_pinned_context.tsx|user_visible_property|Pinned context updated.
      app/frontend/routes/chat/tool_cards/create_repo_document.tsx|user_visible_property|API Guide
      app/frontend/routes/chat/tool_cards/create_repo_document.tsx|user_visible_property|Create **API Guide** in
      app/frontend/routes/chat/tool_cards/delete_repo_document.tsx|user_visible_property|Delete document
      app/frontend/routes/chat/tool_cards/propose_epic.tsx|user_visible_property|Improve proposal cards
      app/frontend/routes/chat/tool_cards/propose_epic.tsx|user_visible_property|Render **rich proposal details**.
      app/frontend/routes/chat/tool_cards/propose_epic.tsx|user_visible_property|Add core cards
      app/frontend/routes/chat/tool_cards/propose_epic.tsx|user_visible_property|Add plugin cards
      app/frontend/routes/chat/tool_cards/propose_epic_with_jobs.tsx|user_visible_property|Release readiness
      app/frontend/routes/chat/tool_cards/propose_epic_with_jobs.tsx|user_visible_property|Coordinate the **release** work.
      app/frontend/routes/chat/tool_cards/propose_epic_with_jobs.tsx|user_visible_property|Prepare release
      app/frontend/routes/chat/tool_cards/propose_epic_with_jobs.tsx|user_visible_property|Prepare artifacts for JOB-12.
      app/frontend/routes/chat/tool_cards/propose_epic_with_jobs.tsx|user_visible_property|Publish release
      app/frontend/routes/chat/tool_cards/propose_epic_with_jobs.tsx|user_visible_property|Publish after preparation.
      app/frontend/routes/chat/tool_cards/propose_job.tsx|user_visible_property|Improve proposal card
      app/frontend/routes/chat/tool_cards/set_bookmark.tsx|user_visible_property|Launch notes
      app/frontend/routes/chat/tool_cards/set_bookmark.tsx|user_visible_property|Epic kickoff
      app/frontend/routes/chat/tool_cards/set_bookmark.tsx|user_visible_property|Nothing yet
      app/frontend/routes/chat/tool_cards/set_bookmark.tsx|user_visible_property|Waiting for result
      app/frontend/routes/chat/tool_cards/spawn_chats.tsx|user_visible_property|Review
      app/frontend/routes/chat/WorkspacePanels.tsx|jsx_expression|(+ -)
      app/frontend/routes/chat/adminToolCard.tsx|jsx_text|JOB-
      app/frontend/routes/chat/adminToolCard.tsx|jsx_text|isValidElement
      app/frontend/routes/chat/adminToolCard.tsx|ternary|mt-1 overflow-visible sm:overflow-x-auto
      app/frontend/routes/chat/chatHelperToolCard.tsx|jsx_text|T | null): CardState
      app/frontend/routes/RepositoryTargetGraph.tsx|jsx_text|THR-
      app/frontend/routes/dashboard/JobsTable.tsx|jsx_text|PR #
      app/frontend/routes/dashboard/KanbanBoard.tsx|jsx_text|PR #
      app/frontend/routes/jobDetail/Delivery.tsx|jsx_text|PR #
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|0 && highlight.start
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|0) blocks.push(`
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|offset || highlight.end
      plugins/git_history/app/frontend/repo_tabs/GitHistory.tsx|jsx_text|, not a fresh
      plugins/git_history/app/frontend/repo_tabs/GitHistory.tsx|jsx_text|-- the Epic's
      plugins/k8s_cluster/app/frontend/components/tabs/EventsTab.tsx|jsx_text|( )
      plugins/mockups/app/frontend/routes/MockupPreviewPanel.tsx|jsx_text|postJson
      plugins/mysql_db_browser/app/frontend/mysqlToolCard.tsx|jsx_text|T | null): MysqlSection
      plugins/scheduled_tasks/app/frontend/routes/CronTemplates.tsx|jsx_text|0) return
      plugins/scheduled_tasks/app/frontend/routes/ScheduledTasks.tsx|jsx_text|0) return
      plugins/team_directory/app/frontend/routes/TeamDirectory.tsx|jsx_text|· ·
      plugins/test_insights/app/frontend/testRunResultsToolCard.tsx|jsx_text|RUN-
      plugins/worker_timeline/app/frontend/components/TimelineLanes.tsx|jsx_text|lastEnd
    LITERALS
  end

  def placeholder_literals
    @placeholder_literals ||= <<~LITERALS.lines.map(&:strip).reject(&:blank?).to_set
      app/frontend/components/credentials/CredentialCard.tsx|jsx_attr|sk-…
      app/frontend/components/credentials/CredentialCard.tsx|jsx_attr|LLM|…
      app/frontend/components/credentials/GithubTokenStep.tsx|jsx_attr|ghp_…
      plugins/codex_agent/app/frontend/components/credentials/CodexConnect.tsx|jsx_attr|sk-…
      plugins/muse_agent/app/frontend/components/credentials/MuseConnect.tsx|jsx_attr|LLM|…
    LITERALS
  end

  def internal_diagnostic_literals
    @internal_diagnostic_literals ||= <<~LITERALS.lines.map(&:strip).reject(&:blank?).to_set
      app/frontend/routes/AdminTranscript.tsx|jsx_text|job log
      app/frontend/routes/jobDetail/SourceBrowser.tsx|jsx_attr|not covered
    LITERALS
  end

  def product_and_provider_names
    %w[
      Claude
      Codex
      GitHub
      MySQL
      OpenAI
      PR
      PDF
      Rails
      SQL
      Syrus
    ]
  end

  def code_like_text
    /
    \A(?:[a-z0-9_.\/:-]+|[A-Z0-9_]+)\z
    |[{};=?`&]
    |\b(?:Array|DataTableColumnDef|InboxEntry|Pick|Promise|Record|ReturnType|Set)\b
    |\b(?:Partial|Number|selection)\b
    /x
  end

  def source_paths
    source_globs.flat_map { |pattern| Dir.glob(Rails.root.join(pattern)) }
      .sort
      .uniq
      .reject { |path| excluded_path_patterns.any? { |pattern| path.match?(pattern) } }
  end

  def allowed_literal?(path, kind, text, allow_chat_debt: true)
    relative_path = path.delete_prefix("#{Rails.root}/")
    return true if allow_chat_debt && CHAT_I18N_DEBT_FILES.include?(relative_path)
    return true if product_and_provider_names.include?(text)
    return true if text.match?(code_like_text)
    return true if internal_diagnostic_path_patterns.any? { |pattern| path.match?(pattern) }
    return true if code_or_protocol_literals.include?("#{relative_path}|#{kind}|#{text}")
    return true if placeholder_literals.include?("#{relative_path}|#{kind}|#{text}")
    return true if internal_diagnostic_literals.include?("#{relative_path}|#{kind}|#{text}")

    false
  end

  def normalized(text)
    text.gsub(/\$?\{[^}]*\}/, "").gsub(/\s+/, " ").strip
  end

  def core_chat_path?(path)
    path.delete_prefix("#{Rails.root}/").start_with?("app/frontend/routes/chat/")
  end

  def add_finding(findings, path, line_number, kind, raw_text, allow_chat_debt: true)
    text = normalized(raw_text)
    return if text.length < 3 || allowed_literal?(path, kind, text, allow_chat_debt: allow_chat_debt)

    label = { "jsx_text" => "JSX text", "jsx_attr" => "JSX attribute", "jsx_expression" => "JSX expression" }.fetch(kind, kind.tr("_", " "))
    findings << "#{path.delete_prefix("#{Rails.root}/")}:#{line_number} #{label}: #{text.inspect}"
  end

  def visible_matches(line, pattern)
    scannable = line.dup
    cursor = 0
    while (assignment = scannable.match(/\bclassName\s*=/, cursor))
      value_start = scannable.index(/[^\s]/, assignment.end(0))
      break unless value_start

      delimiter = scannable[value_start]
      value_end = if %w[" ' `].include?(delimiter)
        scannable.index(delimiter, value_start + 1)
      elsif delimiter == "{"
        depth = 0
        (value_start...scannable.length).find do |index|
          depth += 1 if scannable[index] == "{"
          depth -= 1 if scannable[index] == "}"
          depth.zero?
        end
      end
      break unless value_end

      range = assignment.begin(0)..value_end
      scannable[range] = " " * scannable[range].length
      cursor = value_end + 1
    end

    scannable.scan(pattern)
  end

  def findings_for(path, allow_chat_debt: true)
    File.readlines(path).flat_map.with_index(1) do |line, line_number|
      findings = []

      line.scan(/>([^<>\n]*[A-Za-z][^<>\n]*)</) do |match|
        add_finding(findings, path, line_number, "jsx_text", match.first, allow_chat_debt: allow_chat_debt)
      end

      line.scan(/(?:aria-label|title|placeholder)="([^"]*[A-Za-z][^"]*)"/) do |match|
        add_finding(findings, path, line_number, "jsx_attr", match.first, allow_chat_debt: allow_chat_debt)
      end

      if core_chat_path?(path) || path.include?("/tmp/i18n-audit")
        visible_matches(line, /(?:aria-label|title|placeholder)=\{\s*["'`]([^"'`]*[A-Za-z][^"'`]*)["'`]\s*\}/).each do |match|
          add_finding(findings, path, line_number, "jsx_expression", match.first, allow_chat_debt: allow_chat_debt)
        end

        visible_matches(line, /\{\s*["'`]([^"'`]*[A-Za-z][^"'`]*)["'`]\s*\}/).each do |match|
          add_finding(findings, path, line_number, "jsx_expression", match.first, allow_chat_debt: allow_chat_debt)
        end

        visible_matches(line, /\?\s*["'`]([^"'`]*[A-Za-z][^"'`]*)["'`]\s*:\s*["'`]([^"'`]*[A-Za-z][^"'`]*)["'`]/).each do |match|
          match.each { |text| add_finding(findings, path, line_number, "ternary", text, allow_chat_debt: allow_chat_debt) }
        end

        line.scan(/\b(?:label|title|message|description|placeholder|empty(?:State|_state|Text|_text|Label|_label))\s*[:=]\s*["'`]([^"'`]*[A-Za-z][^"'`]*)["'`]/) do |match|
          add_finding(findings, path, line_number, "user_visible_property", match.first, allow_chat_debt: allow_chat_debt)
        end

        if CHAT_I18N_REVIEWED_FILES.include?(path.delete_prefix("#{Rails.root}/"))
          line.scan(/\b(?:onNotice|set[A-Za-z]+Error)\(\s*["'`]([^"'`]*[A-Za-z][^"'`]*)["'`]/) do |match|
            add_finding(findings, path, line_number, "user_visible_call", match.first, allow_chat_debt: allow_chat_debt)
          end

          line.scan(/\berrorMessage\([^,]+,\s*["'`]([^"'`]*[A-Za-z][^"'`]*)["'`]/) do |match|
            add_finding(findings, path, line_number, "user_visible_fallback", match.first, allow_chat_debt: allow_chat_debt)
          end
        end
      end

      findings
    end
  end

  it "keeps obvious user-visible literals out of source files" do
    findings = source_paths.flat_map { |path| findings_for(path) }

    expect(findings).to be_empty, <<~MESSAGE
      Found untranslated user-visible strings. Move the copy into locale files or add a narrow allowlist for non-user-visible/product/code text:
      #{findings.join("\n")}
    MESSAGE
  end

  it "keeps reviewed chat surfaces out of debt and audits them without debt exemptions" do
    expect(CHAT_I18N_DEBT_FILES & CHAT_I18N_REVIEWED_FILES).to be_empty

    findings = CHAT_I18N_REVIEWED_FILES.flat_map do |relative_path|
      findings_for(Rails.root.join(relative_path).to_s, allow_chat_debt: false)
    end

    expect(findings).to be_empty, <<~MESSAGE
      Reviewed chat surfaces contain untranslated user-visible strings:
      #{findings.join("\n")}
    MESSAGE
  end

  it "detects visible JSX text around interpolation" do
    Tempfile.create([ "i18n-audit", ".tsx" ], Rails.root.join("tmp")) do |file|
      file.write("<span>Owner: {name}</span>")
      file.flush

      expect(findings_for(file.path)).to include(a_string_including('JSX text: "Owner:"'))
    end
  end

  it "detects expression, template, ternary, and common property copy" do
    Tempfile.create([ "i18n-audit", ".tsx" ], Rails.root.join("tmp")) do |file|
      file.write(<<~TSX)
        <span>{"Visible expression"}</span>
        <button title={`Template ${name}`}>x</button>
        const status = ready ? "Ready now" : "Still waiting"
        const option = { label: "Choose repository", emptyState: "Nothing here" }
        <span className="text-sm">{"Expression beside class"}</span>
        <button className="text-sm" title={`Template beside class ${name}`}>x</button>
        <span className={active ? "font-bold" : "font-normal"}>{ready ? "Ready beside class" : "Waiting beside class"}</span>
      TSX
      file.flush

      findings = findings_for(file.path)
      expect(findings).to include(a_string_including('JSX expression: "Visible expression"'))
      expect(findings).to include(a_string_including('JSX expression: "Template"'))
      expect(findings).to include(a_string_including('ternary: "Ready now"'))
      expect(findings).to include(a_string_including('ternary: "Still waiting"'))
      expect(findings).to include(a_string_including('user visible property: "Choose repository"'))
      expect(findings).to include(a_string_including('user visible property: "Nothing here"'))
      expect(findings).to include(a_string_including('JSX expression: "Expression beside class"'))
      expect(findings).to include(a_string_including('JSX expression: "Template beside class"'))
      expect(findings).to include(a_string_including('ternary: "Ready beside class"'))
      expect(findings).to include(a_string_including('ternary: "Waiting beside class"'))
      expect(findings).not_to include(a_string_including('ternary: "font-bold"'))
    end
  end

  it "keeps the core chat debt manifest explicit and valid" do
    expect(CHAT_I18N_DEBT_FILES).to eq(CHAT_I18N_DEBT_FILES.sort.uniq)
    expect(CHAT_I18N_DEBT_FILES).to all(start_with("app/frontend/routes/chat/"))
    expect(CHAT_I18N_DEBT_FILES).to all(satisfy { |path| Rails.root.join(path).file? })
    expect(CHAT_I18N_DEBT_FILES).to all(satisfy { |path| findings_for(Rails.root.join(path).to_s, allow_chat_debt: false).any? })

    chat_wide_exemptions = internal_diagnostic_path_patterns.grep(/app\/frontend\/routes\/chat/)
    expect(chat_wide_exemptions).to be_empty
  end

  it "keeps reviewed admin cards free of the literal copy missed by the conservative scanner" do
    literals_by_path = {
      "app/frontend/routes/chat/tool_cards/admin_maintenance_tasks.tsx" => [ "Task ID", "Definition", "Current step", "Requested by" ],
      "app/frontend/routes/chat/tool_cards/admin_mcp_tool_usage.tsx" => [ "Volume priorities", "Missing high-volume cards", "Unused advertised tools" ],
      "app/frontend/routes/chat/tool_cards/admin_stuck_jobs.tsx" => [ "Attention", "Next action" ]
    }

    literals_by_path.each do |relative_path, literals|
      source = Rails.root.join(relative_path).read
      literals.each do |literal|
        expect(source).not_to match(/["']#{Regexp.escape(literal)}["']/), "#{relative_path} still hard-codes #{literal.inspect}"
      end
    end
  end

  it "translates representative admin-card copy in German and Latin" do
    locales = %w[de la].to_h do |locale|
      [ locale, JSON.parse(Rails.root.join("app/frontend/i18n/locales/#{locale}/chat.json").read) ]
    end
    english = JSON.parse(Rails.root.join("app/frontend/i18n/locales/en/chat.json").read)
    keys = %w[
      ops_no_maintenance_tasks_found_77c53e
      ops_no_mcp_tool_calls_found_for_this_window_d0d947
      ops_fleet_needs_attention_large_result_a725ac
      ops_operational_log_search_failed_f4e50b
      ops_filter_log_rows_840891
      ops_no_stuck_jobs_found_de4657
    ]

    locales.each do |locale, translations|
      keys.each do |key|
        expect(translations.fetch(key)).not_to eq(english.fetch(key)), "#{locale}.chat.#{key} must be translated"
      end
    end
  end

  it "keeps legacy path-level debt exemptions retired" do
    expect(self).not_to respond_to(:legacy_untranslated_paths)
    expect(self).not_to respond_to(:legacy_untranslated_literals)

    user_facing_paths = %w[
      app/frontend/components/diff/ReviewableDiff.tsx
      app/frontend/routes/AdminInvitations.tsx
      app/frontend/routes/AdminQueue.tsx
      app/frontend/routes/AdminStuck.tsx
      app/frontend/routes/ThemesSettings.tsx
    ]

    user_facing_paths.each do |path|
      expect(internal_diagnostic_path_patterns.any? { |pattern| path.match?(pattern) }).to be(false), "#{path} must not be path-allowlisted"
    end
  end

  it "guards strict surfaces against expression-only English copy" do
    diff_review = File.read(Rails.root.join("app/frontend/components/diff/ReviewableDiff.tsx"))
    themes_settings = File.read(Rails.root.join("app/frontend/routes/ThemesSettings.tsx"))

    expect(diff_review).not_to include(">Edit<")
    expect(diff_review).not_to include(">Delete<")
    expect(diff_review).not_to include("`Edit comment ${")
    expect(themes_settings).not_to include("`Delete ${")
    expect(themes_settings).not_to include("`Custom Theme ${")
  end
end
