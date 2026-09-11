require "rails_helper"
require "set"
require "tempfile"

RSpec.describe "Untranslated source strings", type: :unit do
  # Run with:
  #   BUNDLE_PATH="$PWD/vendor/bundle" BUNDLE_APP_CONFIG="$PWD/.bundle" bundle exec rspec spec/i18n
  #
  # This is a deliberately conservative audit for obvious user-visible string
  # literals. It ignores tests, logs, routes, code-like tokens, and existing
  # localized surfaces. Add narrow allowlist entries for legacy debt only; new
  # product copy should move into Rails YAML or frontend/plugin JSON locales.

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

  def legacy_untranslated_paths
    [
      %r{app/frontend/components/(AdminEventActions|Checkbox|FilterBar|ShortcutsHelpModal)\.tsx$},
      %r{app/frontend/components/credentials/},
      %r{app/frontend/components/diff/ReviewableDiff\.tsx$},
      %r{app/frontend/routes/(AdminInvitations|AdminQueue|AdminStuck|AdminTranscript|AdminWorkUnits|AppChromeV2|Chat|Repositories|RepositoryDetail|Tags)\.tsx$},
      %r{app/frontend/routes/appChromeV2/},
      %r{app/frontend/routes/chat/},
      %r{app/frontend/routes/jobDetail/(SourceBrowser|WorkflowGraph)\.tsx$},
      %r{app/frontend/routes/repositoryDetail/DeliveryTracks\.tsx$},
      %r{app/frontend/routes/ThemesSettings\.tsx$},
      %r{desktop/src/App\.tsx$}
    ]
  end

  def legacy_untranslated_literals
    @legacy_untranslated_literals ||= <<~LITERALS.lines.map(&:strip).reject(&:blank?).to_set
      app/frontend/components/CoverageCard.tsx|jsx_text|(threshold: %)
      app/frontend/routes/AdminBackendExceptions.tsx|jsx_text|active job
      app/frontend/routes/AdminMcpToolUsage.tsx|jsx_text|· ·
      app/frontend/routes/AdminReconcilerActivity.tsx|jsx_text|Run #
      app/frontend/routes/AdminUsers.tsx|jsx_text|[`#$`, job.state, job.kind,
      app/frontend/routes/AdminUsers.tsx|jsx_text|[`#$`, run.state, run.trigger_kind,
      app/frontend/routes/AdminWorkflowActivity.tsx|jsx_text|Run #
      app/frontend/routes/EpicDetail.tsx|jsx_text|· Goal #
      app/frontend/routes/JobDetail.tsx|jsx_text|( )
      app/frontend/routes/JobDetail.tsx|jsx_text|· Goal #
      app/frontend/routes/dashboard/JobsTable.tsx|jsx_text|PR #
      app/frontend/routes/dashboard/KanbanBoard.tsx|jsx_text|PR #
      app/frontend/routes/jobDetail/Delivery.tsx|jsx_text|PR #
      plugins/agent_memory/app/frontend/routes/Memories.tsx|jsx_text|Actions
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Add repository
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Block type
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Change mode
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Change summary
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Collaborator user IDs
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Comment
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Comment on selection
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Design doc title
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Design doc title bar
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Design docs
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Editor mode
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Formatting toolbar
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Markdown editor
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|New thread comment
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Optional change summary
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Reply
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Repository associations
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Rich Text editor
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Share visibility
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_attr|Version selection
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|/ saved
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|0 && highlight.start
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|0) blocks.push(`
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Archive
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Current
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Current v
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Design Docs
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Loading design doc...
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Loading design docs...
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Loading...
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Markdown editor
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|New comment on selection
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|No repositories
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|No visible design docs match these filters.
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Owner:
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Pending owner review.
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Private
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Proposed
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Public
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Read only
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Save repositories
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Save sharing
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Share
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Suggest
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Table column actions
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Table row actions
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|This design doc is archived. Content, comments, suggestions, and reviews are read only.
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Threads
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|Updated
      plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx|jsx_text|offset || highlight.end
      plugins/design_docs/app/frontend/tool_cards/comment_on_design_doc.tsx|jsx_text|Comment
      plugins/design_docs/app/frontend/tool_cards/propose_design_doc.tsx|jsx_text|Created
      plugins/design_docs/app/frontend/tool_cards/suggest_design_doc_change.tsx|jsx_text|Conflict
      plugins/design_docs/app/frontend/tool_cards/suggest_design_doc_change.tsx|jsx_text|Suggestion
      plugins/git_history/app/frontend/repo_tabs/GitHistory.tsx|jsx_text|, not a fresh
      plugins/git_history/app/frontend/repo_tabs/GitHistory.tsx|jsx_text|-- the Epic's
      plugins/github_source/app/frontend/repo_tabs/RepositoryIssues.tsx|jsx_text|Loading issues...
      plugins/github_source/app/frontend/repo_tabs/RepositoryIssues.tsx|jsx_text|Select
      plugins/github_source/app/frontend/repo_tabs/RepositoryIssues.tsx|jsx_text|Unable to load issues.
      plugins/k8s_cluster/app/frontend/components/tabs/EventsTab.tsx|jsx_text|( )
      plugins/mockups/app/frontend/previewPanelToolCard.tsx|jsx_text|Open mockup
      plugins/mockups/app/frontend/previewPanelToolCard.tsx|jsx_text|Panel #
      plugins/mockups/app/frontend/routes/MockupPreviewPanel.tsx|jsx_text|postJson
      plugins/mysql_db_browser/app/frontend/mysqlToolCard.tsx|jsx_text|T | null): MysqlSection
      plugins/rails/app/frontend/components/artifacts/ErdDiagramRenderer.tsx|jsx_attr|foreign key
      plugins/rails/app/frontend/components/artifacts/ErdDiagramRenderer.tsx|jsx_text|No tables found in schema.
      plugins/rails/app/frontend/components/artifacts/MigrationDiffRenderer.tsx|jsx_attr|After
      plugins/rails/app/frontend/components/artifacts/MigrationDiffRenderer.tsx|jsx_attr|Before
      plugins/rails/app/frontend/components/artifacts/MigrationDiffRenderer.tsx|jsx_text|Changes
      plugins/scheduled_tasks/app/frontend/routes/CronTemplates.tsx|jsx_text|0) return
      plugins/scheduled_tasks/app/frontend/routes/ScheduledTasks.tsx|jsx_text|0) return
      plugins/scheduled_tasks/app/frontend/tool_cards/fire_scheduled_task_now.tsx|jsx_text|Immediate fire requested
      plugins/scheduled_tasks/app/frontend/tool_cards/fire_scheduled_task_now.tsx|jsx_text|The task does not fire until the operator confirms.
      plugins/scheduled_tasks/app/frontend/tool_cards/list_scheduled_tasks.tsx|jsx_text|Cadence
      plugins/scheduled_tasks/app/frontend/tool_cards/list_scheduled_tasks.tsx|jsx_text|Health
      plugins/scheduled_tasks/app/frontend/tool_cards/list_scheduled_tasks.tsx|jsx_text|Kind
      plugins/scheduled_tasks/app/frontend/tool_cards/list_scheduled_tasks.tsx|jsx_text|Next fire
      plugins/scheduled_tasks/app/frontend/tool_cards/list_scheduled_tasks.tsx|jsx_text|No scheduled tasks for this repository.
      plugins/scheduled_tasks/app/frontend/tool_cards/list_scheduled_tasks.tsx|jsx_text|State
      plugins/scheduled_tasks/app/frontend/tool_cards/list_scheduled_tasks.tsx|jsx_text|Task
      plugins/scheduled_tasks/app/frontend/tool_cards/schedule_recurring.tsx|jsx_text|Not created yet — awaiting operator confirmation.
      plugins/scheduled_tasks/app/frontend/tool_cards/schedule_recurring.tsx|jsx_text|Recurring task proposed
      plugins/scheduled_tasks/app/frontend/tool_cards/update_scheduled_task.tsx|jsx_text|Updated scheduled task
      plugins/team_directory/app/frontend/routes/TeamDirectory.tsx|jsx_text|· updated
      plugins/team_directory/app/frontend/routes/TeamDirectory.tsx|jsx_text|· ·
      plugins/terminal/app/frontend/routes/Terminal.tsx|jsx_attr|Search workspaces
      plugins/terminal/app/frontend/routes/Terminal.tsx|jsx_attr|Search workspaces, chats, workers
      plugins/terminal/app/frontend/routes/Terminal.tsx|jsx_text|No workspace matches
      plugins/test_insights/app/frontend/testRunResultsToolCard.tsx|jsx_attr|Failed / error cases
      plugins/test_insights/app/frontend/testRunResultsToolCard.tsx|jsx_attr|Slow cases
      plugins/test_insights/app/frontend/testRunResultsToolCard.tsx|jsx_text|Duration
      plugins/test_insights/app/frontend/testRunResultsToolCard.tsx|jsx_text|No test results recorded yet.
      plugins/test_insights/app/frontend/testRunResultsToolCard.tsx|jsx_text|RUN-
      plugins/test_insights/app/frontend/testRunResultsToolCard.tsx|jsx_text|Status
      plugins/test_insights/app/frontend/testRunResultsToolCard.tsx|jsx_text|Test
      plugins/test_insights/app/frontend/tool_cards/compare_test_runtime.tsx|jsx_text|Avg delta
      plugins/test_insights/app/frontend/tool_cards/compare_test_runtime.tsx|jsx_text|Baseline avg / p95
      plugins/test_insights/app/frontend/tool_cards/compare_test_runtime.tsx|jsx_text|Comparison avg / p95
      plugins/test_insights/app/frontend/tool_cards/compare_test_runtime.tsx|jsx_text|No matching tests to compare.
      plugins/test_insights/app/frontend/tool_cards/compare_test_runtime.tsx|jsx_text|Test
      plugins/test_insights/app/frontend/tool_cards/list_repository_test_insights.tsx|jsx_text|Avg / last
      plugins/test_insights/app/frontend/tool_cards/list_repository_test_insights.tsx|jsx_text|Category
      plugins/test_insights/app/frontend/tool_cards/list_repository_test_insights.tsx|jsx_text|Failure rate
      plugins/test_insights/app/frontend/tool_cards/list_repository_test_insights.tsx|jsx_text|No tests match this query.
      plugins/test_insights/app/frontend/tool_cards/list_repository_test_insights.tsx|jsx_text|Status
      plugins/test_insights/app/frontend/tool_cards/list_repository_test_insights.tsx|jsx_text|Suite / file
      plugins/test_insights/app/frontend/tool_cards/list_repository_test_insights.tsx|jsx_text|Test
      plugins/throughput/app/frontend/ui_slots/ThroughputPanel.tsx|jsx_attr|Jobs landed
      plugins/throughput/app/frontend/ui_slots/ThroughputPanel.tsx|jsx_attr|Landing units
      plugins/throughput/app/frontend/ui_slots/ThroughputPanel.tsx|jsx_attr|Output
      plugins/throughput/app/frontend/ui_slots/ThroughputPanel.tsx|jsx_attr|PR creation
      plugins/throughput/app/frontend/ui_slots/ThroughputPanel.tsx|jsx_attr|Repository throughput
      plugins/throughput/app/frontend/ui_slots/ThroughputPanel.tsx|jsx_attr|Throughput window
      plugins/throughput/app/frontend/ui_slots/ThroughputPanel.tsx|jsx_text|Approval funnel
      plugins/throughput/app/frontend/ui_slots/ThroughputPanel.tsx|jsx_text|Bottlenecks
      plugins/throughput/app/frontend/ui_slots/ThroughputPanel.tsx|jsx_text|Latency and capacity
      plugins/throughput/app/frontend/ui_slots/ThroughputPanel.tsx|jsx_text|Loading throughput metrics...
      plugins/throughput/app/frontend/ui_slots/ThroughputPanel.tsx|jsx_text|Throughput
      plugins/whiteboard/app/frontend/whiteboardToolCard.tsx|jsx_text|Canvas was already empty.
      plugins/whiteboard/app/frontend/whiteboardToolCard.tsx|jsx_text|Cleared canvas
      plugins/whiteboard/app/frontend/whiteboardToolCard.tsx|jsx_text|Loaded snapshot
      plugins/whiteboard/app/frontend/whiteboardToolCard.tsx|jsx_text|Not saved
      plugins/whiteboard/app/frontend/whiteboardToolCard.tsx|jsx_text|Saved snapshot
      plugins/worker_timeline/app/frontend/components/TimelineLanes.tsx|jsx_text|lastEnd
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
    |\b(?:Array|InboxEntry|Pick|Promise|Record|ReturnType|Set)\b
    |\b(?:Partial|Number|selection)\b
    /x
  end

  def source_paths
    source_globs.flat_map { |pattern| Dir.glob(Rails.root.join(pattern)) }
      .sort
      .uniq
      .reject { |path| excluded_path_patterns.any? { |pattern| path.match?(pattern) } }
  end

  def allowed_literal?(path, kind, text)
    relative_path = path.delete_prefix("#{Rails.root}/")
    return true if product_and_provider_names.include?(text)
    return true if text.match?(code_like_text)
    return true if legacy_untranslated_paths.any? { |pattern| path.match?(pattern) }
    return true if legacy_untranslated_literals.include?("#{relative_path}|#{kind}|#{text}")

    false
  end

  def normalized(text)
    text.gsub(/\{[^}]*\}/, "").gsub(/\s+/, " ").strip
  end

  def findings_for(path)
    File.readlines(path).flat_map.with_index(1) do |line, line_number|
      findings = []

      line.scan(/>([^<>\n]*[A-Za-z][^<>\n]*)</) do |match|
        text = normalized(match.first)
        next if text.length < 3 || allowed_literal?(path, "jsx_text", text)

        findings << "#{path.delete_prefix("#{Rails.root}/")}:#{line_number} JSX text: #{text.inspect}"
      end

      line.scan(/(?:aria-label|title|placeholder)="([^"]*[A-Za-z][^"]*)"/) do |match|
        text = normalized(match.first)
        next if text.length < 3 || allowed_literal?(path, "jsx_attr", text)

        findings << "#{path.delete_prefix("#{Rails.root}/")}:#{line_number} JSX attribute: #{text.inspect}"
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

  it "detects visible JSX text around interpolation" do
    Tempfile.create([ "i18n-audit", ".tsx" ], Rails.root.join("tmp")) do |file|
      file.write("<span>Owner: {name}</span>")
      file.flush

      expect(findings_for(file.path)).to include(a_string_including('JSX text: "Owner:"'))
    end
  end
end
