require "rails_helper"

RSpec.describe SyrusCoverage::OnMiss do
  include ActiveJob::TestHelper

  before { clear_enqueued_jobs }
  after { clear_enqueued_jobs }

  describe ".for" do
    it "resolves known on_miss values to their policy class" do
      expect(described_class.for("block")).to be_a(SyrusCoverage::OnMiss::Block)
      expect(described_class.for("schedule")).to be_a(SyrusCoverage::OnMiss::Schedule)
    end

    it "falls back to Warn for an unrecognized or blank on_miss" do
      expect(described_class.for("warn")).to be_a(SyrusCoverage::OnMiss::Warn)
      expect(described_class.for("bogus")).to be_a(SyrusCoverage::OnMiss::Warn)
      expect(described_class.for(nil)).to be_a(SyrusCoverage::OnMiss::Warn)
    end
  end

  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:logged) { [] }
  let(:log) { ->(chunk) { logged << chunk } }

  describe SyrusCoverage::OnMiss::Block do
    it "logs and raises Steps::Base::StepFailed with the given message" do
      expect {
        subject.call(workflow: workflow, on_miss: "block", message: "coverage too low", log: log)
      }.to raise_error(Steps::Base::StepFailed, "coverage too low")

      expect(logged).to include("[coverage_analyze] threshold miss — failing step")
    end
  end

  describe SyrusCoverage::OnMiss::Schedule do
    it "enqueues SyrusCoverage::ScheduleTriggerJob and logs without raising" do
      expect {
        subject.call(workflow: workflow, on_miss: "schedule", message: "coverage too low", log: log)
      }.not_to raise_error

      expect(SyrusCoverage::ScheduleTriggerJob).to have_been_enqueued.with(workflow.id)
      expect(logged).to include("[coverage_analyze] threshold miss — scheduled coverage fix job")
    end
  end

  describe SyrusCoverage::OnMiss::Warn do
    it "only logs a warning" do
      subject.call(workflow: workflow, on_miss: "warn", message: "coverage too low", log: log)

      expect(logged).to include("[coverage_analyze] threshold miss — warning only (on_miss: warn)")
    end
  end
end
