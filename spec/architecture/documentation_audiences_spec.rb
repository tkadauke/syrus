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
end
