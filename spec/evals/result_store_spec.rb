require "rails_helper"
require Rails.root.join("evals/lib/evals")

RSpec.describe Evals::ResultStore do
  let(:path) { Rails.root.join("tmp/evals_result_store_spec_#{SecureRandom.hex(4)}.jsonl").to_s }

  after { FileUtils.rm_f(path) }

  def result(slug, passed:)
    Evals::ScenarioResult.new(
      scenario_slug: slug, scenario_name: slug, target: "some/SKILL.md", provider: "claude",
      passed: passed, rationale: "because", verifier_error: nil,
      history_intact: true, agent_error: nil, cost_usd: 0.01, turns: 3, ran_at: "2026-08-27T00:00:00Z"
    )
  end

  describe ".append and .history" do
    it "appends one JSON line per result and reads them back" do
      described_class.append(result("scenario_a", passed: true), path: path)
      described_class.append(result("scenario_b", passed: false), path: path)

      rows = described_class.history(path: path)

      expect(rows.size).to eq(2)
      expect(rows.map { |r| r["scenario_slug"] }).to eq(%w[scenario_a scenario_b])
      expect(rows.first["passed"]).to be true
      expect(rows.last["passed"]).to be false
    end

    it "filters history by scenario_slug" do
      described_class.append(result("scenario_a", passed: true), path: path)
      described_class.append(result("scenario_b", passed: true), path: path)
      described_class.append(result("scenario_a", passed: false), path: path)

      rows = described_class.history(scenario_slug: "scenario_a", path: path)

      expect(rows.size).to eq(2)
      expect(rows).to all(include("scenario_slug" => "scenario_a"))
    end

    it "returns an empty array when nothing has been recorded yet" do
      expect(described_class.history(path: path)).to eq([])
    end

    it "creates intermediate directories on first append" do
      nested_path = Rails.root.join("tmp/evals_result_store_spec_nested_#{SecureRandom.hex(4)}/history.jsonl").to_s

      described_class.append(result("scenario_a", passed: true), path: nested_path)

      expect(File).to exist(nested_path)
      FileUtils.rm_rf(File.dirname(nested_path))
    end
  end
end
