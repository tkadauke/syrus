require "rails_helper"

RSpec.describe Workflows::UpstreamExport do
  let(:user) { Factories.user }
  let(:canonical) { Factories.repository(user: user, default_branch: "main") }
  let(:repository) { Factories.repository(user: user, default_branch: "main", upstream_repository: canonical) }
  let(:job) { Factories.job_record(user: user, repository: repository, issue_number: 1, state: "approved", branch_name: "syrus/issue-1") }

  describe ".instantiate" do
    it "sets trigger_kind to upstream_export" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.trigger_kind).to eq("upstream_export")
    end

    it "dispatches directly onto the existing job rather than a synthetic anchor job" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.job).to eq(job)
    end

    it "declares a single non-agentic publish step — no assemble/grade loop" do
      workflow = described_class.instantiate(job: job)

      kinds = workflow.steps.order(:position).pluck(:kind)
      expect(kinds).to eq(%w[upstream_export_publish])
    end

    it "uses the merges queue" do
      expect(described_class.queue_name).to eq(:merges)
    end
  end
end
