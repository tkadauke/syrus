require "rails_helper"

RSpec.describe TestEvidenceLookup do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:run) { workflow.steps.first.runs.first || workflow.steps.first.runs.create!(job: job, trigger_kind: "initial", state: "failed") }

  def fake_provider(failed_test_cases:)
    Module.new do
      define_singleton_method(:failed_test_cases) { |run:, grader_name:| failed_test_cases }
    end
  end

  def stub_provider(provider)
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:test_evidence).and_return([ provider ])
  end

  describe ".failed_test_summary_for" do
    it "returns nil when there is no run" do
      stub_provider(fake_provider(failed_test_cases: [ { "suite_name" => "S", "name" => "n" } ]))

      expect(described_class.failed_test_summary_for(nil, "rspec")).to be_nil
    end

    it "returns nil when grader_name is blank" do
      stub_provider(fake_provider(failed_test_cases: [ { "suite_name" => "S", "name" => "n" } ]))

      expect(described_class.failed_test_summary_for(run, "")).to be_nil
    end

    it "returns nil when no provider has failures for this run/grader" do
      stub_provider(fake_provider(failed_test_cases: []))

      expect(described_class.failed_test_summary_for(run, "rspec")).to be_nil
    end

    it "returns a bounded summary with the total count and first-N failures" do
      failures = (1..8).map { |n| { "suite_name" => "spec/s_spec.rb", "name" => "case #{n}" } }
      stub_provider(fake_provider(failed_test_cases: failures))

      summary = described_class.failed_test_summary_for(run, "rspec", limit: 3)

      expect(summary).to eq(
        "grader_name" => "rspec",
        "failed_count" => 8,
        "failures" => failures.first(3),
        "omitted_count" => 5
      )
    end

    it "reports zero omitted when every failure fits within the limit" do
      failures = [ { "suite_name" => "spec/s_spec.rb", "name" => "case 1" } ]
      stub_provider(fake_provider(failed_test_cases: failures))

      summary = described_class.failed_test_summary_for(run, "rspec", limit: 5)

      expect(summary["omitted_count"]).to eq(0)
      expect(summary["failures"]).to eq(failures)
    end
  end
end
