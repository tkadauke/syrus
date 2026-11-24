require "rails_helper"

# Coverage analysis belongs to the syrus_coverage plugin. Core keeps only the
# ecosystem family contract (`CoverageAnalysis::Parsers`, the `analyze_coverage`
# capability) and the grader-side capture of declared coverage outputs, which
# graders own. This guards the rest from drifting back.
RSpec.describe "Coverage plugin boundary" do
  OWNED_COVERAGE_NAMES = /
    CoverageSnapshot | RepoCoveragePlan | CoverageArtifact | CoverageProjects | CoverageOnMiss |
    CoverageReport\b | CoverageHit | CoverageSchedule | coverage_analyze\b | coverage_pr_comment |
    coverage_hit_map | get_coverage_report | coverage_snapshots
  /x

  # Core files that legitimately name the plugin. The configured-or-not flag on
  # the repository summary reads the plugin's `.syrus.yml` contribution by key.
  ALLOWED_COVERAGE_REFERENCES = [
    "app/controllers/api/v1/app/repositories_controller.rb"
  ].freeze

  def core_files
    roots = %w[app lib config bin].map { |dir| Rails.root.join(dir) }
    roots.flat_map { |root| Dir.glob(root.join("**/*.{rb,yml,rake}")) }
         .reject { |path| path.include?("/app/frontend/") || path.include?("/config/syrus_docs/") }
         .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
  end

  it "keeps coverage analysis out of core Ruby and config" do
    offenders = core_files.filter_map do |path|
      next if ALLOWED_COVERAGE_REFERENCES.include?(path)

      matches = Rails.root.join(path).read.lines.each_with_index.filter_map { |line, index| "#{path}:#{index + 1}" if line.match?(OWNED_COVERAGE_NAMES) }
      matches.first
    end

    expect(offenders).to be_empty, "coverage references belong in plugins/syrus_coverage: #{offenders.join(', ')}"
  end

  # The coverage card, trend sparkline, trend API client and their strings live
  # under the plugin and reach core pages through `job.detail` and
  # `repository.detail` slots. (The source browser's line overlay and diff
  # annotations are part of core's diff/source viewer and read the Job payload's
  # `coverage` key; they are not listed here.)
  FRONTEND_OWNED_COVERAGE = /CoverageCard|CoverageSparkline|fetchRepositoryCoverageTrend|CoverageTrend(Point|Payload)|coverage_trend_|"coverage_(title|unavailable|files_show|project_col_project)"/

  it "keeps the coverage card, sparkline and their locale keys out of core frontend files" do
    files = Dir.glob(Rails.root.join("app/frontend/**/*.{ts,tsx,json}")).map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
    offenders = files.filter_map do |path|
      next if path.start_with?("app/frontend/i18n/locales/") && !path.end_with?("jobs.json", "settings.json")

      Rails.root.join(path).read.lines.each_with_index.filter_map { |line, index| "#{path}:#{index + 1}" if line.match?(FRONTEND_OWNED_COVERAGE) }.first
    end

    expect(offenders).to be_empty, "coverage UI belongs in plugins/syrus_coverage/app/frontend: #{offenders.join(', ')}"
  end

  it "keeps the step kinds in the plugin, not in core's Step::Kind" do
    core_kinds = Step::Kind::BUILT_IN_ENTRIES.map(&:kind)

    expect(core_kinds).not_to include("coverage_analyze", "coverage_pr_comment")
  end

  it "keeps no coverage table or migration in core beyond the historical ones" do
    core_migrations = Dir.glob(Rails.root.join("db/migrate/*coverage*.rb")).map { |path| File.basename(path) }

    # Historical migrations create the original table; the plugin renames it.
    expect(core_migrations).to contain_exactly(
      "20260706210606_create_coverage_snapshots.rb",
      "20260910123000_add_project_identity_to_coverage_snapshots.rb"
    )
  end

  it "keeps the ecosystem coverage contract in core" do
    expect(defined?(CoverageAnalysis::Parsers::Base::ParseResult)).to be_truthy
    expect(Syrus::Plugin::Ecosystem::GraderCoverage.instance_methods).to include(:coverage_for_phases?)
  end
end
