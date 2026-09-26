require "rails_helper"

RSpec.describe "frontend table conventions" do
  FRONTEND_TABLE_GLOBS = [
    "app/frontend/**/*.tsx",
    "plugins/*/app/frontend/**/*.tsx"
  ].freeze

  # Intentional raw-table exceptions from the final table audit. Everything
  # not listed here should use DataTable.Root or a higher-level shared table
  # wrapper so it gets shared overflow, header, sort, and column-control
  # conventions. Tool cards stay raw only where they render compact,
  # transcript-embedded result summaries instead of reusable application lists.
  RAW_TABLE_EXCEPTIONS = {
    "app/frontend/components/CoverageCard.tsx" => "nested coverage report details, not a filterable record grid",
    "app/frontend/components/FilePreviewModal.tsx" => "monospace file preview grid with fixed code-like layout",
    "app/frontend/components/artifacts/coreArtifactRenderers.tsx" => "artifact renderer for externally supplied tabular payloads",
    "app/frontend/components/diff/ReviewableDiff.tsx" => "diff renderer with specialized unified/split layout semantics",
    "app/frontend/lib/Markdown.tsx" => "markdown renderer emits author-provided table markup",
    "app/frontend/routes/RetentionSettings.tsx" => "per-table archive history mini-list nested under retention policy rows",
    "app/frontend/routes/chat/issueTagArtifactToolCard.tsx" => "compact chat tool-card result summary",
    "app/frontend/routes/chat/repoDocumentToolCard.tsx" => "compact chat tool-card result summary",
    "app/frontend/routes/chat/tool_cards/admin_stuck_jobs.tsx" => "compact chat tool-card result summary",
    "app/frontend/routes/chat/tool_cards/list_artifacts.tsx" => "compact chat tool-card result summary",
    "app/frontend/routes/chat/tool_cards/list_delivery_tracks.tsx" => "compact chat tool-card result summary",
    "app/frontend/routes/chat/tool_cards/list_epics.tsx" => "compact chat tool-card result summary",
    "app/frontend/routes/chat/tool_cards/list_job_workflows.tsx" => "compact chat tool-card result summary",
    "app/frontend/routes/chat/tool_cards/list_open_prs.tsx" => "compact chat tool-card result summary",
    "app/frontend/routes/chat/tool_cards/list_proposals.tsx" => "compact chat tool-card result summary",
    "app/frontend/routes/chat/tool_cards/list_ref_movement_actions.tsx" => "compact chat tool-card result summary",
    "app/frontend/routes/chat/tool_cards/list_repositories.tsx" => "compact chat tool-card result summary",
    "app/frontend/routes/chat/tool_cards/list_wakeups.tsx" => "compact chat tool-card result summary",
    "app/frontend/routes/jobDetail/SourceBrowser.tsx" => "coverage-annotated source renderer with monospace line layout",
    "plugins/admin_mysql/app/frontend/adminMysqlToolCard.tsx" => "compact chat tool-card result summary",
    "plugins/agent_insights/app/frontend/repo_tabs/RepositoryInsights.tsx" => "nested model metric detail table inside one insight card",
    "plugins/agent_memory/app/frontend/memoryToolCard.tsx" => "compact chat tool-card result summary",
    "plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx" => "HTML string fixture used by design-doc editor tests",
    "plugins/mysql_db_browser/app/frontend/tool_cards/mysql_db_browser_describe_table.tsx" => "compact chat tool-card result summary",
    "plugins/mysql_db_browser/app/frontend/tool_cards/mysql_db_browser_execute_query.tsx" => "compact chat tool-card result summary",
    "plugins/mysql_db_browser/app/frontend/tool_cards/mysql_db_browser_list_connections.tsx" => "compact chat tool-card result summary",
    "plugins/mysql_db_browser/app/frontend/tool_cards/mysql_db_browser_list_databases.tsx" => "compact chat tool-card result summary",
    "plugins/mysql_db_browser/app/frontend/tool_cards/mysql_db_browser_list_tables.tsx" => "compact chat tool-card result summary",
    "plugins/rails/app/frontend/components/artifacts/ErdDiagramRenderer.tsx" => "artifact renderer for schema diagrams",
    "plugins/rails/app/frontend/components/artifacts/MigrationDiffRenderer.tsx" => "artifact renderer for migration before/after diffs",
    "plugins/scheduled_tasks/app/frontend/tool_cards/list_scheduled_tasks.tsx" => "compact chat tool-card result summary",
    "plugins/test_insights/app/frontend/testRunResultsToolCard.tsx" => "compact chat tool-card result summary",
    "plugins/test_insights/app/frontend/tool_cards/compare_test_runtime.tsx" => "compact chat tool-card result summary",
    "plugins/test_insights/app/frontend/tool_cards/list_repository_test_insights.tsx" => "compact chat tool-card result summary",
    "plugins/theming_tools/app/frontend/themeToolCard.tsx" => "compact chat tool-card result summary"
  }.freeze

  # Direct DataTable users should normally opt into the shared column
  # primitives (DataTableColumnHeaderRow + DataTableColumnMenu) or the
  # AdminEventLogTable/AdminDataTablePanel wrappers, which provide sortable
  # headers, visible-column selection, header drag reorder, and selector
  # reorder. These exceptions are deliberately narrower: compact embedded
  # summaries, fixed diagnostic matrices, detail-only subtables, or dashboard
  # tables whose equivalent controls are driven by persisted dashboard
  # preferences instead of local column preferences.
  DIRECT_DATA_TABLE_CONTROL_EXCEPTIONS = {
    "app/frontend/routes/AdminInstallations.tsx#root1" => "credential-mode comparison matrix, not a record list",
    "app/frontend/routes/AdminMaintenanceTasks.tsx#root1" => "maintenance-task detail event log, not the index table",
    "app/frontend/routes/AdminMcpToolUsage.tsx#root1" => "fixed MCP startup-phase latency diagnostic table",
    "app/frontend/routes/AdminMcpToolUsage.tsx#root2" => "compact MCP tool leaderboard with fixed numeric columns",
    "app/frontend/routes/AdminMcpToolUsage.tsx#root3" => "compact MCP usage breakdown with fixed numeric columns",
    "app/frontend/routes/AdminPlugins.tsx#root1" => "plugin detail metric subtable with a fixed schema",
    "app/frontend/routes/AdminPlugins.tsx#root2" => "plugin detail extension-point subtable with a fixed schema",
    "app/frontend/routes/AdminQueue.tsx#root1" => "per-worker health minute-bucket diagnostic table",
    "app/frontend/routes/AdminQueue.tsx#root2" => "per-worker health trend diagnostic table",
    "app/frontend/routes/AdminUsers.tsx#root1" => "user detail recent-activity mini-list without stable column definitions",
    "app/frontend/routes/RepositoryDetail.tsx#root1" => "repository detail triage-release action table",
    "app/frontend/routes/RepositoryForm.tsx#root1" => "credential-mode comparison matrix, not a record list",
    "app/frontend/routes/chat/adminToolCard.tsx#root1" => "compact chat tool-card result summary",
    "app/frontend/routes/chat/jobsTableCard.tsx#root1" => "compact chat tool-card result summary",
    "app/frontend/routes/dashboard/EpicWorkflowTables.tsx#root1" => "dashboard epic table uses dashboard preference controls for sort and column reorder",
    "app/frontend/routes/dashboard/EpicWorkflowTables.tsx#root2" => "dashboard workflow table uses dashboard preference controls for sort and column reorder",
    "app/frontend/routes/dashboard/JobsTable.tsx#root1" => "dashboard job table uses dashboard preference controls for sort and column reorder",
    "plugins/agent_insights/app/frontend/agentInsightToolCard.tsx#root1" => "compact chat tool-card result summary",
    "plugins/mysql_db_browser/app/frontend/routes/MysqlConnections.tsx#root1" => "schema-detail column table has database-defined columns",
    "plugins/plugin_runtime/app/frontend/routes/AdminPluginServices.tsx#root1" => "service-detail diagnostic table is shaped by the selected service",
    "plugins/scheduled_tasks/app/frontend/routes/CronTemplates.tsx#root1" => "cron template detail applied-tasks subtable",
    "plugins/scheduled_tasks/app/frontend/routes/ScheduledTasks.tsx#root1" => "scheduled-task detail recent-jobs subtable, not the index table",
    "plugins/syrus_dev/app/frontend/routes/AdminPerformance.tsx#root1" => "SQL explain rows expose database-defined columns",
    "plugins/syrus_dev/app/frontend/routes/AdminPerformance.tsx#root3" => "performance detail rows expose dynamic diagnostic columns",
    "plugins/syrus_dev/app/frontend/routes/AdminPerformance.tsx#root4" => "local performance table wrapper uses caller-provided controls",
    "plugins/test_insights/app/frontend/repo_tabs/RepositoryTests.tsx#root2" => "test detail history table uses dedicated pagination and fixed columns"
  }.freeze

  it "keeps raw table usage explicitly audited" do
    raw_table_paths = frontend_sources.filter_map do |path|
      next if path == "app/frontend/components/ui/DataTable.tsx"

      path if Rails.root.join(path).read.include?("<table")
    end

    expect(raw_table_paths).to match_array(RAW_TABLE_EXCEPTIONS.keys)
  end

  it "does not reintroduce literal caret sort indicators" do
    offenders = frontend_sources.filter_map do |path|
      source = Rails.root.join(path).read
      next unless source.match?(/(?:sort|Sort)[\s\S]{0,120}(?:["']\^["']|["']v["'])/)

      path
    end

    expect(offenders).to be_empty
  end

  it "keeps direct DataTable control omissions explicitly audited" do
    direct_table_instances = frontend_sources.flat_map do |path|
      next if path == "app/frontend/components/ui/DataTable.tsx"

      source = Rails.root.join(path).read
      table_root_offsets(source).filter_map.with_index(1) do |offset, ordinal|
        block = direct_table_root_block(source, offset)
        next if block.include?("DataTableColumnHeaderRow") && source.include?("DataTableColumnMenu")

        "#{path}#root#{ordinal}"
      end
    end.compact

    expect(direct_table_instances).to match_array(DIRECT_DATA_TABLE_CONTROL_EXCEPTIONS.keys)
  end

  def frontend_sources
    FRONTEND_TABLE_GLOBS.flat_map { |glob| Dir.glob(Rails.root.join(glob)) }
      .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }
      .reject { |path| path.match?(/\.(?:test|spec)\.tsx\z/) }
      .sort
  end

  def table_root_offsets(source)
    source.enum_for(:scan, /<DataTable\.Root\b/).map { Regexp.last_match.begin(0) }
  end

  def direct_table_root_block(source, offset)
    close_offset = source.index("</DataTable.Root>", offset)
    return source[offset..] unless close_offset

    source[offset..close_offset]
  end
end
