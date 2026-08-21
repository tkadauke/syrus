require "rails_helper"

RSpec.describe Workflow::SccacheArtifact do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:run) { workflow.steps.first.runs.first || workflow.steps.first.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }

  describe ".read" do
    it "returns [] when nothing has been captured yet" do
      expect(described_class.read(workflow)).to eq([])
    end

    it "returns the recorded entries in capture order" do
      described_class.record!(workflow, run: run, step_kind: "prepare", label: "bundle install", stats: { "compile_requests" => 1 })
      described_class.record!(workflow, run: run, step_kind: "grader", label: "rspec", stats: { "compile_requests" => 2 })

      entries = described_class.read(workflow.reload)
      expect(entries.map { |e| e["label"] }).to eq([ "bundle install", "rspec" ])
    end
  end

  describe ".record!" do
    it "appends an entry with run/step metadata alongside the raw stats payload" do
      entry = described_class.record!(
        workflow, run: run, step_kind: "grader", label: "rspec",
        stats: { "cache_hits" => { "counts" => { "C/C++" => 3 } } }
      )

      expect(entry).to include(
        "run_id"    => run.id,
        "step_kind" => "grader",
        "label"     => "rspec",
        "iteration" => run.iteration,
        "stats"     => { "cache_hits" => { "counts" => { "C/C++" => 3 } } }
      )
      expect(entry["captured_at"]).to be_present

      persisted = workflow.reload.artifact(described_class::ARTIFACT_KEY)
      expect(persisted).to eq([ entry ])
    end

    it "does not overwrite earlier captures" do
      described_class.record!(workflow, run: run, step_kind: "prepare", label: "npm ci", stats: {})
      described_class.record!(workflow, run: run, step_kind: "prepare", label: "bundle install", stats: {})

      expect(workflow.reload.artifact(described_class::ARTIFACT_KEY).size).to eq(2)
    end
  end

  describe "ARTIFACT_KEY" do
    it "is 'sccache_stats'" do
      expect(described_class::ARTIFACT_KEY).to eq("sccache_stats")
    end
  end
end
