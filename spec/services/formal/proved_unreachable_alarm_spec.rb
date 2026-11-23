require "rails_helper"
require "json"
require "tmpdir"

# Proofs as production alarms (formal/INTEGRATION.md, layer 4): a reconciler
# issue kind whose state the models prove unreachable is marked
# `"expected": "never"` in formal/coverage/coverage.json. Any production event
# of that kind means an assumption is wrong or a model has drifted.
RSpec.describe Formal::ProvedUnreachableAlarm do
  let(:now) { Time.zone.parse("2026-11-23 12:00:00") }

  def event(kind, at:)
    WorkEngineReconcilerActivityEvent.create!(event_type: "issues_detected", source: "spec", issue_kind: kind,
      message: "detected #{kind}", details: {}, occurred_at: at)
  end

  def coverage(items)
    dir = Pathname.new(Dir.mktmpdir("coverage"))
    dir.join("coverage.json").write(JSON.generate("items" => items))
    dir.join("coverage.json")
  end

  let(:path) do
    coverage([
      { "id" => "proved", "status" => "done", "expected" => "never", "issue_kinds" => %w[impossible_state] },
      { "id" => "repaired", "status" => "done", "issue_kinds" => %w[ordinary_state] }
    ])
  end

  it "reports a proved-unreachable issue kind seen in the window, with its count and last sighting" do
    event("impossible_state", at: now - 2.hours)
    latest = event("impossible_state", at: now - 1.hour)
    event("ordinary_state", at: now - 1.hour)

    result = described_class.call(since: now - 24.hours, coverage_path: path)

    expect(result.watched_kinds).to eq(%w[impossible_state])
    expect(result.sightings.size).to eq(1)
    expect(result.sightings.first).to have_attributes(item_id: "proved", issue_kind: "impossible_state", count: 2,
      last_seen_at: latest.occurred_at)
    expect(result.sightings.first.sample_event_ids).to include(latest.id)
    expect(result).not_to be_quiet
  end

  it "is quiet when no proved-unreachable kind occurred in the window" do
    event("impossible_state", at: now - 3.days)
    event("ordinary_state", at: now - 1.hour)

    expect(described_class.call(since: now - 24.hours, coverage_path: path)).to be_quiet
  end

  it "watches exactly the inventory entries the repository marks expected never" do
    watched = described_class.call(since: now).watched_kinds

    expect(watched).to include("terminal_work_unit_active_locks", "closed_job_requested_work_intent")
    items = JSON.parse(Rails.root.join("formal/coverage/coverage.json").read).fetch("items").select { |item| item["expected"] == "never" }
    expect(items).to all(include("status" => "done"))
    expect(items.flat_map { |item| item.fetch("issue_kinds") }).to match_array(watched)
  end
end
