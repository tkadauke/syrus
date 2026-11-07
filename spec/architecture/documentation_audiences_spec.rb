# frozen_string_literal: true

require_relative "../../app/models/retention_policy_registry"

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

  it "splits workflow, settings, feature-flag, deploy, and MCP docs by audience" do
    architecture_pages = %w[workflow-steps app-settings feature-flags mcp-tool-usage]
    operations_pages = %w[data-retention deploying-syrus resource-limits]
    architecture_index = root.join("docs/engineering/architecture/README.md").read
    operations_index = root.join("docs/engineering/operations/README.md").read

    architecture_pages.each do |page|
      expect(root.join("docs/engineering/architecture/#{page}.md")).to exist
      expect(architecture_index).to include("(#{page}.md)")
    end
    operations_pages.each do |page|
      expect(root.join("docs/engineering/operations/#{page}.md")).to exist
      expect(operations_index).to include("(#{page}.md)")
    end

    expect(root.join("config/syrus_docs/mcp_tool_usage.md").read.lines.length).to be <= 45
    expect(root.join("config/syrus_docs/deploy.md").read).not_to include("## Two-version compatibility")
    expect(root.join("config/syrus_docs/feature_flags.md").read).not_to include("## performance_logging")
    expect(root.join("config/syrus_docs/workflow_steps.md").read).not_to include("## Grader command spans")
    searchable_app_settings = root.join("config/syrus_docs/app_settings.md").read
    expect(searchable_app_settings).not_to include("RetentionPolicyRegistry")
    RetentionPolicyRegistry::CORE_DEFINITIONS.each do |definition|
      expect(searchable_app_settings).to include(
        "| `#{definition.setting_key}` | #{definition.default_value} #{definition.unit} |"
      )
    end

    expect(root.join("docs/engineering/operations/deploying-syrus.md").read).to include("DB_PREPARE_ATTEMPTS")
    expect(root.join("docs/engineering/operations/data-retention.md").read).to include("RetentionPolicyRegistry")
    expect(root.join("docs/engineering/architecture/mcp-tool-usage.md").read).to include("custom_card_gaps")
    expect(root.join("docs/engineering/architecture/feature-flags.md").read).to include("per_spawn_resource_limits")
    expect(root.join("docs/engineering/architecture/app-settings.md").read).to include("WorkflowStepResourceProfile")
    expect(root.join("docs/engineering/architecture/workflow-steps.md").read).to include("CommandSpan")
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

  it "splits workflow, settings, feature-flag, deploy, and MCP docs by audience" do
    architecture_pages = %w[workflow-steps app-settings feature-flags mcp-tool-usage]
    operations_pages = %w[data-retention deploying-syrus resource-limits]
    architecture_index = root.join("docs/engineering/architecture/README.md").read
    operations_index = root.join("docs/engineering/operations/README.md").read

    architecture_pages.each do |page|
      expect(root.join("docs/engineering/architecture/#{page}.md")).to exist
      expect(architecture_index).to include("(#{page}.md)")
    end
    operations_pages.each do |page|
      expect(root.join("docs/engineering/operations/#{page}.md")).to exist
      expect(operations_index).to include("(#{page}.md)")
    end

    expect(root.join("config/syrus_docs/mcp_tool_usage.md").read.lines.length).to be <= 45
    expect(root.join("config/syrus_docs/deploy.md").read).not_to include("## Two-version compatibility")
    expect(root.join("config/syrus_docs/feature_flags.md").read).not_to include("## performance_logging")
    expect(root.join("config/syrus_docs/workflow_steps.md").read).not_to include("## Grader command spans")
    expect(root.join("config/syrus_docs/app_settings.md").read).not_to include("RetentionPolicyRegistry")

    expect(root.join("docs/engineering/operations/deploying-syrus.md").read).to include("DB_PREPARE_ATTEMPTS")
    expect(root.join("docs/engineering/operations/data-retention.md").read).to include("RetentionPolicyRegistry")
    expect(root.join("docs/engineering/architecture/mcp-tool-usage.md").read).to include("custom_card_gaps")
    expect(root.join("docs/engineering/architecture/feature-flags.md").read).to include("per_spawn_resource_limits")
    expect(root.join("docs/engineering/architecture/app-settings.md").read).to include("WorkflowStepResourceProfile")
    expect(root.join("docs/engineering/architecture/workflow-steps.md").read).to include("CommandSpan")
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

  it "splits workflow, settings, feature-flag, deploy, and MCP docs by audience" do
    architecture_pages = %w[workflow-steps app-settings feature-flags mcp-tool-usage]
    operations_pages = %w[data-retention deploying-syrus resource-limits]
    architecture_index = root.join("docs/engineering/architecture/README.md").read
    operations_index = root.join("docs/engineering/operations/README.md").read

    architecture_pages.each do |page|
      expect(root.join("docs/engineering/architecture/#{page}.md")).to exist
      expect(architecture_index).to include("(#{page}.md)")
    end
    operations_pages.each do |page|
      expect(root.join("docs/engineering/operations/#{page}.md")).to exist
      expect(operations_index).to include("(#{page}.md)")
    end

    expect(root.join("config/syrus_docs/mcp_tool_usage.md").read.lines.length).to be <= 45
    expect(root.join("config/syrus_docs/deploy.md").read).not_to include("## Two-version compatibility")
    expect(root.join("config/syrus_docs/feature_flags.md").read).not_to include("## performance_logging")
    expect(root.join("config/syrus_docs/workflow_steps.md").read).not_to include("## Grader command spans")
    expect(root.join("config/syrus_docs/app_settings.md").read).not_to include("RetentionPolicyRegistry")

    expect(root.join("docs/engineering/operations/deploying-syrus.md").read).to include("DB_PREPARE_ATTEMPTS")
    expect(root.join("docs/engineering/operations/data-retention.md").read).to include("RetentionPolicyRegistry")
    expect(root.join("docs/engineering/architecture/mcp-tool-usage.md").read).to include("custom_card_gaps")
    expect(root.join("docs/engineering/architecture/feature-flags.md").read).to include("per_spawn_resource_limits")
    expect(root.join("docs/engineering/architecture/app-settings.md").read).to include("WorkflowStepResourceProfile")
    expect(root.join("docs/engineering/architecture/workflow-steps.md").read).to include("CommandSpan")
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

  it "splits remaining mixed feature guides by audience" do
    architecture_pages = %w[
      preview-panels preview-environments admin-recovery delivery-tracks
      typed-artifacts workflow-warnings chat-speech-to-text
      github-permission-sync external-platforms dashboard-views
      chat-scheduled-messages
    ]
    operations_pages = %w[
      preview-environments admin-recovery ios-compute chat-speech-to-text
    ]
    architecture_index = root.join("docs/engineering/architecture/README.md").read
    operations_index = root.join("docs/engineering/operations/README.md").read
    preview_architecture = root.join("docs/engineering/architecture/preview-environments.md").read
    preview_operations = root.join("docs/engineering/operations/preview-environments.md").read
    recovery_architecture = root.join("docs/engineering/architecture/admin-recovery.md").read
    recovery_operations = root.join("docs/engineering/operations/admin-recovery.md").read
    stt_architecture = root.join("docs/engineering/architecture/chat-speech-to-text.md").read
    stt_operations = root.join("docs/engineering/operations/chat-speech-to-text.md").read
    typed_artifacts = root.join("docs/engineering/architecture/typed-artifacts.md").read
    plugin_authoring = root.join("docs/engineering/conventions/plugins/authoring.md").read
    rails_plugin = root.join("plugins/rails/docs/syrus_docs/rails.md").read

    architecture_pages.each do |page|
      expect(root.join("docs/engineering/architecture/#{page}.md")).to exist
      expect(architecture_index).to include("(#{page}.md)")
    end
    operations_pages.each do |page|
      expect(root.join("docs/engineering/operations/#{page}.md")).to exist
      expect(operations_index).to include("(#{page}.md)")
    end

    expect(root.join("config/syrus_docs/preview_panels.md").read)
      .not_to include("PreviewProxyMiddleware")
    expect(root.join("config/syrus_docs/preview_environments.md").read)
      .not_to include("PreviewControlServer")
    expect(root.join("config/syrus_docs/admin_recovery.md").read)
      .not_to include("RestartWatcher")
    expect(root.join("config/syrus_docs/delivery_tracks.md").read)
      .not_to include("LandingQueueProcessor")
    expect(root.join("config/syrus_docs/typed_artifacts.md").read)
      .not_to include("WorkspacePanels.tsx")
    expect(root.join("config/syrus_docs/workflow_warnings.md").read)
      .not_to include("WorkflowWarnings.record!")
    expect(root.join("config/syrus_docs/chat_speech_to_text.md").read)
      .not_to include("ActionCable")
    expect(root.join("config/syrus_docs/github_permission_sync.md").read)
      .not_to include("GithubPermissionSyncer")
    expect(root.join("config/syrus_docs/external_platforms.md").read)
      .not_to include("InboundMessageRouter")
    expect(root.join("config/syrus_docs/dashboard_views.md").read)
      .not_to include("Filters::SmartFolderResolution")
    expect(root.join("config/syrus_docs/chat_scheduled_messages.md").read)
      .not_to include("ScheduledChatMessageFireJob")

    expect(preview_architecture).to include("PreviewProxyMiddleware", "PreviewControlServer", "error_reason")
    expect(preview_architecture).not_to include("## Production setup")
    expect(preview_operations).to include("SYRUS_PREVIEW_BASE_DOMAIN", "## Production setup")
    expect(preview_operations).not_to include("PreviewEnvironment#error_reason")
    expect(preview_architecture).not_to eq(preview_operations)

    expect(recovery_architecture).to include("## Admin mutation feedback")
    expect(recovery_architecture).not_to include("RestartWatcher")
    expect(recovery_operations).to include("RestartWatcher", "SIGTERM", "restart: unless-stopped")
    expect(recovery_operations).not_to include("## Admin mutation feedback")
    expect(recovery_architecture).not_to eq(recovery_operations)

    expect(stt_architecture).to include("ChatDictationChannel", "audio_chunk", "chat_speech_to_text.*")
    expect(stt_architecture).not_to include("## Deploying the backend")
    expect(stt_operations).to include("whisper-stt", "SYRUS_STT_PROVIDER=whisper_stt")
    expect(stt_operations).not_to include("ChatDictationChannel")
    expect(stt_architecture).not_to eq(stt_operations)

    expect(typed_artifacts).not_to include("Syrus::PluginRegistry.register", "uniquely named disposable database")
    expect(plugin_authoring).to include("provides: { artifact_renderer:")
    expect(rails_plugin).to include("uniquely named disposable database", "storage_unavailable")
  end

  it "keeps the remaining harness guides focused on supported behavior" do
    forbidden_details = {
      "issue_triage.md" => %w[JobClassificationAttempt ClassifyIssueJob accept_triage],
      "skills.md" => %w[Skills::ParameterSchema SkillJobs::Creator workflow_serializers.rb ChatTurnJob],
      "chat_goals.md" => %w[ChatGoalIterationAuditor ChatScopedEvent ChatQueuedMessagePromoter ChatTurnJob],
      "target_graph.md" => %w[TargetHealthRecord NestedConfigDiscovery TargetGraph:: Steps:: /api/v1/app/repositories],
      "coverage.md" => %w[CoverageHitMapPruneJob CoverageSnapshot.where],
      "local_mode.md" => %w[LocalTunnelChannel LocalDaemonSessionController],
      "pr_feedback_classification.md" => %w[PrCommentClassifier classification_decision pr_review_comments],
      "epicless_job_bundling.md" => %w[JobBundleDispatcher JobsTable.tsx landing_queue_entry_key],
      "push_protection_recovery.md" => %w[GithubPushProtection::Rejected Steps::PushProtectionRecovery SYRUS_DATA_ROOT],
      "landing_queue.md" => %w[LandingValidationCache work_unit_locks WorkUnits::Ownership LandingQueueProcessor StepDispatcher /api/v1/],
      "trigger_kinds.md" => %w[SkillJobs::Creator Admin::JobStateSerializer PollPullRequestJob StepDispatcher app/models/workflow],
      "external_pr_ingestion.md" => %w[PollExternalPrJob PollPullRequestJob PrCommentIngester Workflows:: external_pr_number],
      "adversarial_review.md" => %w[Prompts::AdversarialReview workflow.artifacts],
      "repository_readiness.md" => %w[execution-probes single-flight],
      "emergency_land.md" => %w[EmergencyLand::Permission emergency_landed_by_user_id]
    }

    forbidden_details.each do |filename, terms|
      searchable = root.join("config/syrus_docs", filename).read
      terms.each { |term| expect(searchable).not_to include(term) }
    end

    implementation_free_pages = %w[
      target_graph.md landing_queue.md trigger_kinds.md chat_goals.md skills.md
      external_pr_ingestion.md
    ]
    implementation_patterns = {
      "Ruby class/module names" => /\b[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)+/,
      "Ruby method references" => /\b[A-Z][A-Za-z0-9]*#[a-z_]/,
      "internal application paths" => %r{(?<![\w-])app/(?:models|services|frontend)/},
      "UI-only REST routes" => %r{/api/v1/}
    }

    implementation_free_pages.each do |filename|
      searchable = root.join("config/syrus_docs", filename).read
      prose = searchable.gsub(/```.*?```/m, "")

      implementation_patterns.each do |description, pattern|
        expect(prose).not_to match(pattern), "#{filename} contains #{description}"
      end
    end

    expect(root.join("config/syrus_docs/reconciliation.md")).not_to exist
    expect(root.join("config/syrus_docs/merge_train.md").read)
      .to include("## Reconciliation phase")

    operations = root.join("docs/engineering/operations/README.md").read
    expect(root.join("docs/engineering/operations/external-pr-ingestion.md")).to exist
    expect(operations).to include("(external-pr-ingestion.md)")

    ios_plugin = root.join("plugins/ios/docs/syrus_docs/ios.md").read
    expect(ios_plugin).to include('"planned_execution"', '"ios_simulator"')
  end
end
