require "rails_helper"

RSpec.describe CognitiveCoverage::SnapshotBuilder do
  include ActiveSupport::Testing::TimeHelpers

  let(:repository) { Factories.repository(owner: "acme", name: "widgets", default_branch: "main") }
  let(:generated_at) { Time.zone.parse("2026-09-28 12:00:00 UTC") }

  def line(path, number, modified_at:, complexity: 0)
    CognitiveCoverage::LineFact.new(
      path: path,
      line_number: number,
      last_modified_at: Time.zone.parse(modified_at),
      complexity: complexity
    )
  end

  def engagement(path, number, engaged_at:, source: "diff_review_comment", source_sha: "target")
    CognitiveCoverage::Engagement.new(
      path: path,
      line_number: number,
      engaged_at: Time.zone.parse(engaged_at),
      source: source,
      source_sha: source_sha
    )
  end

  def build_snapshot(line_facts:, engagements:, **overrides)
    described_class.call(**{
      repository: repository,
      target_sha: "target",
      line_facts: line_facts,
      engagements: engagements,
      coverage_snapshot: instance_double(CoverageSnapshot, data: {}),
      target_health_records: [],
      generated_at: generated_at
    }.merge(overrides))
  end

  it "classifies a line as covered when engagement is newer than the line and inside the freshness window" do
    snapshot = build_snapshot(
      line_facts: [ line("app/models/widget.rb", 1, modified_at: "2026-09-01") ],
      engagements: [ engagement("app/models/widget.rb", 1, engaged_at: "2026-09-20") ]
    )

    expect(snapshot.line_results.first.state).to eq("covered")
    expect(snapshot.files.fetch("app/models/widget.rb")).to have_attributes(
      line_count: 1,
      covered_count: 1,
      stale_count: 0,
      blind_count: 0
    )
  end

  it "marks engagement stale when later code changes supersede it" do
    snapshot = build_snapshot(
      line_facts: [ line("app/models/widget.rb", 1, modified_at: "2026-09-20") ],
      engagements: [ engagement("app/models/widget.rb", 1, engaged_at: "2026-09-01") ]
    )

    expect(snapshot.line_results.first.state).to eq("stale")
  end

  it "marks engagement stale after the configured ninety-day threshold" do
    snapshot = build_snapshot(
      line_facts: [ line("app/models/widget.rb", 1, modified_at: "2026-01-01") ],
      engagements: [ engagement("app/models/widget.rb", 1, engaged_at: "2026-06-01") ]
    )

    expect(snapshot.line_results.first.state).to eq("stale")
  end

  it "rolls blind and covered lines up to file, subsystem, and repository totals" do
    snapshot = build_snapshot(
      line_facts: [
        line("app/models/widget.rb", 1, modified_at: "2026-09-01"),
        line("app/models/widget.rb", 2, modified_at: "2026-09-01")
      ],
      engagements: [ engagement("app/models/widget.rb", 1, engaged_at: "2026-09-20") ]
    )

    expect(snapshot.line_results.map(&:state)).to eq(%w[covered blind])
    expect(snapshot.files.fetch("app/models/widget.rb")).to have_attributes(line_count: 2, covered_count: 1, blind_count: 1)
    expect(snapshot.subsystems.fetch("app")).to have_attributes(line_count: 2, covered_count: 1, blind_count: 1)
    expect(snapshot.repository_rollup).to have_attributes(key: "acme/widgets", line_count: 2, covered_count: 1, blind_count: 1)
  end

  it "ranks blind, churning, untested, complex files above covered files" do
    coverage = instance_double(
      CoverageSnapshot,
      data: {
        "app/risky.rb" => { "lines_pct" => 0.0 },
        "app/calm.rb" => { "lines_pct" => 95.0 }
      }
    )

    snapshot = build_snapshot(
      line_facts: [
        line("app/risky.rb", 1, modified_at: "2026-09-01", complexity: 3),
        line("app/risky.rb", 2, modified_at: "2026-09-01", complexity: 3),
        line("app/calm.rb", 1, modified_at: "2026-09-01")
      ],
      engagements: [ engagement("app/calm.rb", 1, engaged_at: "2026-09-20") ],
      change_frequency: { "app/risky.rb" => 8, "app/calm.rb" => 0 },
      coverage_snapshot: coverage
    )

    file_items = snapshot.ranked_items.select { |item| item.kind == "file" }
    expect(file_items.first.key).to eq("app/risky.rb")
    expect(file_items.first.risk_score).to be > file_items.second.risk_score
  end

  it "preserves explanation breakdowns for ranked items" do
    coverage = instance_double(CoverageSnapshot, data: { "app/risky.rb" => { "lines_pct" => 0.0 } })
    target_health = TargetHealthRecord.new(status: "failed")

    snapshot = build_snapshot(
      line_facts: [
        line("app/risky.rb", 1, modified_at: "2026-01-01", complexity: 3),
        line("app/risky.rb", 2, modified_at: "2026-01-01", complexity: 3)
      ],
      engagements: [],
      change_frequency: { "app/risky.rb" => 7 },
      coverage_snapshot: coverage,
      target_health_records: [ target_health ],
      reliability_signals: { "app/risky.rb" => 1 }
    )

    risky = snapshot.ranked_items.find { |item| item.kind == "file" && item.key == "app/risky.rb" }
    expect(risky.explanations).to include(
      "blind",
      "high churn",
      "untested",
      "high complexity",
      "unhealthy target",
      "old blind code",
      "recent reliability signal"
    )
  end
end
