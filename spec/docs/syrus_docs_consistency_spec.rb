# frozen_string_literal: true

require "rails_helper"
require "yaml"

RSpec.describe "Syrus operator docs consistency" do
  def read_doc(path)
    Rails.root.join(path).read
  end

  def markdown_headings(path, level:)
    marker = "#" * level
    read_doc(path).scan(/^#{Regexp.escape(marker)}\s+(.+)$/).flatten
  end

  def documented_identifiers(path, level:)
    markdown_headings(path, level: level).flat_map do |heading|
      identifiers = heading.scan(/`([^`]+)`/).flatten
      identifiers = heading.split(/\s+\/\s+/).map { |part| part.sub(/\A`/, "").sub(/`\z/, "") } if identifiers.empty?
      identifiers
    end
  end

  def feature_slugs
    YAML.safe_load(read_doc("config/features.yml")).fetch("features").map { |entry| entry.fetch("slug") }
  end

  it "documents every workflow trigger kind in the operator trigger reference" do
    documented = documented_identifiers("config/syrus_docs/trigger_kinds.md", level: 2)

    expect(documented).to include(*Workflow::TriggerKind.values)
  end

  it "documents every step kind in the operator step reference" do
    documented = documented_identifiers("config/syrus_docs/workflow_steps.md", level: 3)

    expect(documented).to include(*Step::Kind.values)
  end

  it "documents every feature flag declared in config/features.yml" do
    documented = documented_identifiers("config/syrus_docs/feature_flags.md", level: 2)

    expect(documented).to include(*feature_slugs)
  end

  it "documents every persisted AppSetting column operators can configure" do
    ignored_columns = %w[id created_at updated_at]
    documented = documented_identifiers("config/syrus_docs/app_settings.md", level: 3)

    expect(documented).to include(*(AppSetting.column_names - ignored_columns))
  end

  it "keeps chain descriptions aligned on steps introduced by the workflow registries" do
    trigger_docs = read_doc("config/syrus_docs/trigger_kinds.md")
    architecture = read_doc("ARCHITECTURE.md")

    expect(trigger_docs).to include("`prepare → optional loop(respond → adversarial_review) → retry_until(respond → grader_fanout → grader_collect) → coverage_analyze → coverage_pr_comment → summarize_amend → try(push)`")
    expect(trigger_docs).to include("`prepare → optional loop(implement → adversarial_review) → retry_until(implement → grader_fanout → grader_collect) → coverage_analyze → summarize → test_plan → pr_open`")
    expect(trigger_docs).to include("`prepare → preflight_grader_fanout → [preflight_grader steps] → preflight_grader_collect → retry_until(implement → grader_fanout → grader_collect) → summarize → test_plan → pr_open`")
    expect(trigger_docs).to include("`prepare → agent_insight_run → auto_close`")

    expect(architecture).to include("`merge_train_assemble → merge_train_build → merge_train_reconcile → prepare → retry_until(grader_fanout → grader_collect, repair: landing_fix) → coverage_analyze? → try(merge_train_land)`")
    expect(architecture).to include("`prepare → grader_fanout → grader_collect`")
    expect(architecture).to include("`prepare → agent_insight_run → auto_close`")
  end

  it "keeps MCP tool usage docs tied to the tool registry metadata shape" do
    docs = read_doc("config/syrus_docs/mcp_tool_usage.md")
    summary_keys = McpToolRegistry.summaries.first.keys.map(&:to_s)

    expect(docs).to include("McpToolRegistry")
    expect(docs).to include(*summary_keys.intersection(%w[tool_name surface tier admin_only feature_flag required_roles capability mutation read_only]))
  end
end
