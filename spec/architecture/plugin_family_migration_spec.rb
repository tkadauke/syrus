require "rails_helper"

RSpec.describe "Plugin family migration architecture" do
  ECOSYSTEM_POINTS = %i[
    prepare_detector grade_detector grader_type grader_augmentor review_criteria_provider
    autofix_command dependency_audit_command focused_test_command coverage_analyzer
    affected_test_analyzer ci_log_parser prompt_injector diff_review_file_pattern_provider
    build_system_graph_provider
  ].freeze

  # Add a family only after all core callers use Dispatch; entries map the
  # family to every absorbed point so the assertion cannot silently narrow.
  DISPATCHED_FAMILIES = { ecosystem: ECOSYSTEM_POINTS }.freeze

  # The bridge is live while core callers and bundled plugins move in later
  # changes. A migrating family must own every legacy point up front.
  MIGRATING_FAMILIES = { ecosystem: ECOSYSTEM_POINTS }.freeze

  # The bridge is live while core callers and bundled plugins move in later
  # changes. A migrating family must own every legacy point up front.
  MIGRATING_FAMILIES = { ecosystem: ECOSYSTEM_POINTS }.freeze

  # The bridge is live while core callers and bundled plugins move in later
  # changes. A migrating family must own every legacy point up front.
  MIGRATING_FAMILIES = { ecosystem: ECOSYSTEM_POINTS }.freeze

  # The bridge is live while core callers and bundled plugins move in later
  # changes. A migrating family must own every legacy point up front.
  MIGRATING_FAMILIES = { ecosystem: ECOSYSTEM_POINTS }.freeze

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

  it "marks Ecosystem as migrating with a complete legacy bridge" do
    definition = Syrus::Plugin::Family.fetch(:ecosystem)

    expect(MIGRATING_FAMILIES.fetch(:ecosystem)).to match_array(ECOSYSTEM_POINTS)
    expect(definition.legacy_mappings.keys).to match_array(ECOSYSTEM_POINTS)
    expect(definition).not_to be_migrated
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
