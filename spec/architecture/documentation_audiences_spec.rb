# frozen_string_literal: true

RSpec.describe "documentation audiences" do
  let(:root) { Pathname.new(File.expand_path("../..", __dir__)) }
  let(:guidance) { root.join("CLAUDE.md").read }
  let(:workflow_config) { root.join(".syrus.yml").read }
  let(:engineering_index) { root.join("docs/engineering/README.md").read }

  it "keeps the cross-project searchable-doc rule aligned" do
    [guidance, engineering_index].each do |document|
      normalized = document.gsub(/\s+/, " ")

      expect(normalized).to include("searchable by chat and implementation agents working on any project")
      expect(normalized).to include("response compression")
      expect(normalized).to include("payload shapes")
      expect(normalized).to include("caching")
      expect(normalized).to include("polling")
    end

    expect(workflow_config).to include("Do not require searchable\n      harness docs for internal-only implementation changes")
  end

  it "routes internal documentation to existing engineering owners" do
    destinations = %w[
      conventions architecture maps operations decisions pitfalls
    ]

    destinations.each do |destination|
      expect(root.join("docs/engineering", destination, "README.md")).to exist
      expect(guidance).to include("docs/engineering/#{destination}/")
      expect(engineering_index).to include("`#{destination}/`")
    end

    plugin_guide = root.join("docs/engineering/conventions/plugins.md")
    expect(plugin_guide).to exist
    expect(guidance).to include("docs/engineering/conventions/plugins.md")
    expect(engineering_index).to include("`conventions/plugins.md`")
  end

  it "keeps internal and operational references out of searchable harness docs" do
    engineering_pages = {
      conventions: %w[
        design_system_eslint_ratchet semantic_ui style_debt_report
        server_localization process_execution rollout_compatibility
        app_setting_scope_audit
      ],
      architecture: %w[
        workflow_cancellation_attribution workspace_reuse_outcomes
        workflow_artifacts workflow_workspace_lifecycle
        permission_shadow_evaluation worker_activity_timeline
        work_engine_reconciler persistent_mcp_sidecar agent_conversation
        admin_api_prefixes admin_api_catalog coding_workspace_relay
      ],
      operations: %w[macos_worker_updates docker_compose]
    }

    engineering_pages.each do |section, pages|
      index = root.join("docs/engineering", section.to_s, "README.md").read

      pages.each do |page|
        expect(root.join("docs/engineering", section.to_s, "#{page}.md")).to exist
        expect(index).to include("(#{page}.md)")
        expect(root.join("config/syrus_docs", "#{page}.md")).not_to exist
      end
    end
  end

  it "retains concise behavior-only searchable summaries" do
    summaries = {
      "diff_review_comments.md" => %w[chat_feedback generated renderable_files],
      "connected_platforms.md" => %w[Telegram Discord 15],
      "input_sources.md" => %w[GitHub Linear source-control],
      "repository_feature_recommendations.md" => %w[visual scheduled off]
    }

    summaries.each do |filename, behavior_terms|
      content = root.join("config/syrus_docs", filename).read

      expect(content.lines.length).to be <= 25
      behavior_terms.each { |term| expect(content).to include(term) }
      expect(content).to include("docs/engineering/architecture/")
    end

    chat = root.join("config/syrus_docs/chat.md").read
    expect(chat).to include("## Repository files and Coding Mode workspaces")
    expect(chat).to include("`submit_coding_changes`")
    expect(chat).to include("`reset_workspace`")
  end
  it "splits chat, worker, metrics, and observability docs by audience" do
    architecture_index = root.join("docs/engineering/architecture/README.md").read
    operations_index = root.join("docs/engineering/operations/README.md").read

    %w[chat multi-worker metrics observability].each do |page|
      expect(root.join("docs/engineering/architecture/#{page}.md")).to exist
      expect(architecture_index).to include("(#{page}.md)")
    end

    %w[multi-worker metrics observability].each do |page|
      expect(root.join("docs/engineering/operations/#{page}.md")).to exist
      expect(operations_index).to include("(#{page}.md)")
    end

    expect(root.join("config/syrus_docs/metrics.md")).not_to exist

    searchable_chat = root.join("config/syrus_docs/chat.md").read
    searchable_workers = root.join("config/syrus_docs/multi_worker.md").read
    searchable_observability = root.join("config/syrus_docs/observability.md").read

    expect(searchable_chat).to include("`submit_coding_changes`")
    expect(searchable_chat).to include("`failed_step`")
    expect(searchable_chat).to include("`cancel_stale_work` uses a `targets` array")
    expect(searchable_chat).to include("`satisfaction_mode`")
    expect(searchable_chat).to include("`spawn_chats`")
    expect(searchable_chat).not_to include("CodexRolloutSanitizer")
    expect(searchable_workers).to include("SYRUS_WORKER_CAPABILITIES")
    expect(searchable_workers).to include("no_capable_worker")
    expect(searchable_workers).to include("AppSetting.max_concurrent_agent_runs")
    expect(searchable_workers).to include("AppSetting.host_admission_policy")
    expect(searchable_workers).to include("AppSetting.workflow_admission_policy")
    expect(searchable_workers).not_to include("db/search_migrate")
    expect(searchable_observability).to include("SYRUS_ALERT_WEBHOOK_URL")
    expect(searchable_observability).to include("browser_error_auto_reports")
    expect(searchable_observability).to include("ops.read_logs")
    expect(searchable_observability).not_to include("Observability::EventSink")

    architecture_chat = root.join("docs/engineering/architecture/chat.md").read
    architecture_workers = root.join("docs/engineering/architecture/multi-worker.md").read
    operations_workers = root.join("docs/engineering/operations/multi-worker.md").read
    architecture_observability = root.join("docs/engineering/architecture/observability.md").read
    operations_observability = root.join("docs/engineering/operations/observability.md").read

    expect(architecture_chat).not_to include("`schedule_wakeup` continues the current conversation")
    expect(architecture_workers).not_to include("## Spreading workers across nodes")
    expect(operations_workers).to include("## Native macOS compute workers")
    expect(operations_workers).to include("### Docker Compose CPU sizing")
    expect(architecture_observability).not_to include("### On-demand process diagnostics")
    expect(operations_observability).to include("### On-demand process diagnostics")
  end

  it "splits chat, worker, metrics, and observability docs by audience" do
    architecture_index = root.join("docs/engineering/architecture/README.md").read
    operations_index = root.join("docs/engineering/operations/README.md").read

    %w[chat multi-worker metrics observability].each do |page|
      expect(root.join("docs/engineering/architecture/#{page}.md")).to exist
      expect(architecture_index).to include("(#{page}.md)")
    end

    %w[multi-worker metrics].each do |page|
      expect(root.join("docs/engineering/operations/#{page}.md")).to exist
      expect(operations_index).to include("(#{page}.md)")
    end

    expect(root.join("config/syrus_docs/metrics.md")).not_to exist

    searchable_chat = root.join("config/syrus_docs/chat.md").read
    searchable_workers = root.join("config/syrus_docs/multi_worker.md").read
    searchable_observability = root.join("config/syrus_docs/observability.md").read

    expect(searchable_chat).to include("`submit_coding_changes`")
    expect(searchable_chat).not_to include("CodexRolloutSanitizer")
    expect(searchable_workers).to include("SYRUS_WORKER_CAPABILITIES")
    expect(searchable_workers).not_to include("db/search_migrate")
    expect(searchable_observability).to include("SYRUS_ALERT_WEBHOOK_URL")
    expect(searchable_observability).not_to include("Observability::EventSink")
  end

  it "keeps plugin authoring out of the searchable behavior guide" do
    searchable = root.join("config/syrus_docs/plugins.md").read
    authoring = root.join("docs/engineering/conventions/plugins/authoring.md").read
    conventions = root.join("docs/engineering/conventions/README.md").read
    plugin_readme = root.join("plugins/README.md").read

    expect(searchable.lines.length).to be < 500
    %w[
      runtime_acquire_control known_flaky_failure_dismissal_enabled
      isolated_repro_dismissal_enabled grader_type base_retry
      prepare_detector autofix_command dependency_audit_command
      affected_test_analyzer review_criteria_provider
      build_system_graph_provider execution_backend secret_env
    ].each { |term| expect(searchable).to include(term) }
    expect(searchable).to include("`ios` — enabled iOS project intelligence")
    expect(searchable).to include("`throughput` — enabled delivery-throughput views")
    expect(searchable).not_to include("Syrus::PluginRegistry.register")
    expect(searchable).not_to include("app/services/")

    %w[
      preview_provider runtime_session_provider mcp_tool_set
      diff_review_annotation_provider callbacks prompt_injector
      artifact_renderer tool_card workspace_tab search_source workflow_kinds
      memory_store domain_subscriber ui_slot slug_type grader_augmentor
      repository_content_provider workspace_git_transport
    ].each { |term| expect(authoring).to include(term) }
    expect(authoring.lines.length).to be >= 4_000
    expect(conventions).to include("(plugins/authoring.md)")
    expect(plugin_readme).to include("docs/engineering/conventions/plugins/authoring.md")
  end

  it "does not link searchable docs to anchors that moved out of plugins.md" do
    dirs = ["config/syrus_docs/*.md", "plugins/*/docs/syrus_docs/*.md"]
    offenders = dirs.flat_map { |g| Dir[root.join(g).to_s] }.flat_map do |f|
      File.read(f).scan(/\]\(plugins\.md#[^)]*\)/).map { |m| "#{f}: #{m}" }
    end
    expect(offenders).to be_empty
  end
end
