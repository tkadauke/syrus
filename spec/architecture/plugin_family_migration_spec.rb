require "rails_helper"

RSpec.describe "Plugin family migration architecture" do
  ECOSYSTEM_POINTS = %i[
    prepare_detector grade_detector grader_type grader_augmentor review_criteria_provider
    autofix_command dependency_audit_command focused_test_command coverage_analyzer
    affected_test_analyzer ci_log_parser prompt_injector diff_review_file_pattern_provider
    build_system_graph_provider
  ].freeze
  TOOLKIT_POINTS = %i[
    mcp_tool_set chat_mcp_tool_set permission_provider mcp_run_context_contributor
  ].freeze
  SURFACE_POINTS = %i[
    sidebar_page admin_page repo_page_tab workspace_tab ui_slot artifact_renderer preview_panel_viewer
  ].freeze
  CHAT_INTEGRATION_POINTS = %i[
    chat_payload_contributor chat_prompt_injector chat_media_source chat_turn_orientation
    chat_turn_finalizer chat_workspace_lifecycle chat_turn_lifecycle chat_job_status_extension
    chat_identity_provider mentionable
  ].freeze

  # Add a family only after all core callers use Dispatch; entries map the
  # family to every absorbed point so the assertion cannot silently narrow.
  DISPATCHED_FAMILIES = {
    ecosystem: ECOSYSTEM_POINTS,
    # Toolkit keeps an explicit compatibility bridge for external plugins
    # during the family migration; core callers must still use Dispatch.
    toolkit: TOOLKIT_POINTS,
    surface: SURFACE_POINTS,
    chat_integration: CHAT_INTEGRATION_POINTS
  }.freeze

  it "keeps Toolkit's compatibility allowlist explicit" do
    definition = Syrus::Plugin::Family.fetch(:toolkit)

    expect(definition.legacy_mappings.keys).to contain_exactly(*TOOLKIT_POINTS)
    expect(Syrus::PluginRegistry::EXTENSION_POINTS & TOOLKIT_POINTS).to contain_exactly(*TOOLKIT_POINTS)
  end

  it "keeps Surface's compatibility allowlist explicit" do
    definition = Syrus::Plugin::Family.fetch(:surface)

    expect(definition.legacy_mappings.keys).to contain_exactly(*SURFACE_POINTS)
    expect(Syrus::PluginRegistry::EXTENSION_POINTS & SURFACE_POINTS).to contain_exactly(*SURFACE_POINTS)
  end

  it "allows no bundled plugin to register a legacy point absorbed by Surface" do
    actual = SURFACE_POINTS.to_h do |point|
      plugins = Dir["plugins/*/lib/*.rb"].filter_map do |path|
        File.basename(File.dirname(File.dirname(path))) if registrations_in(File.read(path), point).positive?
      end
      [ point, plugins.sort ]
    end

    expect(actual).to eq(SURFACE_POINTS.index_with { [] })
  end

  it "keeps ChatIntegration's compatibility allowlist explicit" do
    definition = Syrus::Plugin::Family.fetch(:chat_integration)
    expect(definition.legacy_mappings.keys).to contain_exactly(*CHAT_INTEGRATION_POINTS)
    expect(Syrus::PluginRegistry::EXTENSION_POINTS & CHAT_INTEGRATION_POINTS).to contain_exactly(*CHAT_INTEGRATION_POINTS)
  end

  it "allows no bundled plugin to register a legacy point absorbed by ChatIntegration" do
    actual = CHAT_INTEGRATION_POINTS.to_h do |point|
      plugins = Dir["plugins/*/lib/*.rb"].filter_map do |path|
        File.basename(File.dirname(File.dirname(path))) if registrations_in(File.read(path), point).positive?
      end
      [ point, plugins.sort ]
    end
    expect(actual).to eq(CHAT_INTEGRATION_POINTS.index_with { [] })
  end

  def registrations_in(source, point)
    source.scan(/\b#{Regexp.escape(point.to_s)}\s*:/).length
  end

  def forbidden_migrated_lookups(source, migrated_families)
    migrated_families.flat_map do |family, points|
      points.filter_map { |point| [ family, point ] if source.match?(/providers_for\(\s*:#{Regexp.escape(point.to_s)}\b/) }
    end
  end

  it "allows no bundled plugin to register a legacy point absorbed by Ecosystem" do
    actual = ECOSYSTEM_POINTS.to_h do |point|
      plugins = Dir["plugins/*/lib/*.rb"].filter_map do |path|
        File.basename(File.dirname(File.dirname(path))) if registrations_in(File.read(path), point).positive?
      end
      [ point, plugins.sort ]
    end

    expect(actual).to eq(ECOSYSTEM_POINTS.index_with { [] })
  end

  it "keeps bundled plugin documentation off removed Ecosystem point names" do
    violations = Dir["plugins/**/*.{md,markdown}"].flat_map do |path|
      source = File.read(path)
      ECOSYSTEM_POINTS.filter_map do |point|
        "#{path}: :#{point}" if source.match?(/:#{Regexp.escape(point.to_s)}\b/)
      end
    end

    expect(violations).to be_empty
  end

  it "marks Ecosystem as migrated without a legacy bridge" do
    definition = Syrus::Plugin::Family.fetch(:ecosystem)

    expect(definition.legacy_mappings).to be_empty
    expect(definition).to be_migrated
    expect(Syrus::PluginRegistry::EXTENSION_POINTS & ECOSYSTEM_POINTS).to be_empty
  end

  it "detects a legacy registration in a manifest fixture" do
    fixture = "provides prepare_detector: NewLanguage::Prepare"
    expect(registrations_in(fixture, :prepare_detector)).to eq(1)
    expect(ECOSYSTEM_POINTS).to include(:prepare_detector)
  end

  it "keeps dispatched-family core callers off legacy registry lookups" do
    core = Dir["{app,lib}/**/*.rb"].to_h { |path| [ path, File.read(path) ] }
    violations = core.flat_map do |path, source|
      forbidden_migrated_lookups(source, DISPATCHED_FAMILIES).map { |family, point| "#{path}: #{family}/#{point}" }
    end
    expect(violations).to be_empty
  end

  it "demonstrates that a migrated-family legacy lookup fixture fails" do
    fixture = "Syrus::PluginRegistry.providers_for(:prepare_detector)"
    expect(forbidden_migrated_lookups(fixture, ecosystem: [ :prepare_detector ]))
      .to eq([ [ :ecosystem, :prepare_detector ] ])
  end

  it "demonstrates that an incomplete family mapping fixture fails" do
    expect do
      Syrus::Plugin::Family.define(:incomplete_architecture_fixture) do
        shape :facet
        absorbs :prepare_detector
        capability :detect_prepare, composition: :collect, absent: [], tier: :stable, context: String
      end
    end.to raise_error(ArgumentError, /missing legacy mappings for prepare_detector/)
  ensure
    Syrus::Plugin::Family.instance_variable_get(:@definitions).delete(:incomplete_architecture_fixture)
  end
end
