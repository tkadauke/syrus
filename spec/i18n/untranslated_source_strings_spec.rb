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
      %r{app/frontend/components/ui/Text\.tsx$},
      %r{app/frontend/components/credentials/},
      %r{app/frontend/components/diff/ReviewableDiff\.tsx$},
      %r{app/frontend/routes/(AdminInvitations|AdminQueue|AdminStuck|AdminTranscript)\.tsx$},
      %r{app/frontend/routes/appChromeV2/},
      %r{app/frontend/routes/chat/},
      %r{app/frontend/routes/jobDetail/(SourceBrowser|WorkflowGraph)\.tsx$},
      %r{app/frontend/routes/repositoryDetail/DeliveryTracks\.tsx$},
      %r{app/frontend/routes/ThemesSettings\.tsx$},
      %r{desktop/src/App\.tsx$},
      %r{plugins/admin_mysql/app/frontend/adminMysqlToolCard\.tsx$},
      %r{plugins/agent_insights/app/frontend/agentInsightToolCard\.tsx$},
      %r{plugins/browser/app/frontend/browserToolCard\.tsx$},
      %r{plugins/github_source/app/frontend/routes/AdminGithubApiUsage\.tsx$},
      %r{plugins/theming_tools/app/frontend/themeToolCard\.tsx$}
    ]
  end

  def legacy_untranslated_literals
    @legacy_untranslated_literals ||= <<~LITERALS.lines.map(&:strip).reject(&:blank?).to_set
      app/frontend/components/CoverageCard.tsx|jsx_text|(threshold: %)
      app/frontend/components/AdminEventActions.tsx|jsx_text|JOB-
      app/frontend/components/Checkbox.tsx|jsx_text|in a
      app/frontend/components/ShortcutsHelpModal.tsx|jsx_text|(items: T[]): ShortcutGroupSummary
      app/frontend/routes/AdminBackendExceptions.tsx|jsx_text|active job
      app/frontend/routes/AdminMcpToolUsage.tsx|jsx_text|· ·
      app/frontend/routes/AdminReconcilerActivity.tsx|jsx_text|Run #
      app/frontend/routes/AdminUsers.tsx|jsx_text|[`#$`, job.state, job.kind,
      app/frontend/routes/AdminUsers.tsx|jsx_text|[`#$`, run.state, run.trigger_kind,
      app/frontend/routes/AdminWorkflowActivity.tsx|jsx_text|Run #
      app/frontend/routes/AdminWorkUnits.tsx|jsx_text|WI-
      app/frontend/routes/AdminWorkUnits.tsx|jsx_text|WU-
      app/frontend/routes/AppChromeV2.tsx|jsx_text|queryClient.getQueryData
      app/frontend/routes/EpicDetail.tsx|jsx_text|· Goal #
      app/frontend/routes/JobDetail.tsx|jsx_text|( )
      app/frontend/routes/JobDetail.tsx|jsx_text|· Goal #
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
