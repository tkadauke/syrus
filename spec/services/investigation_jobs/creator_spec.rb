require "rails_helper"

RSpec.describe InvestigationJobs::Creator do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  describe ".call" do
    it "creates a direct Job flagged investigation and dispatches an investigation Workflow" do
      result = described_class.call(
        user: user,
        repository: repository,
        prompt: "Figure out why /dashboard feels slow."
      )

      expect(result).to be_success
      job = result.job
      expect(job.kind).to eq("direct")
      expect(job.investigation?).to eq(true)
      expect(job.issue_number).to be_nil
      expect(job.issue_body).to eq("Figure out why /dashboard feels slow.")

      workflow = job.workflows.last
      expect(workflow.trigger_kind).to eq("investigation")
      expect(workflow.work_unit).to be_present
    end

    it "defaults to medium priority and the repository's effective agent provider" do
      result = described_class.call(user: user, repository: repository, prompt: "Investigate something.")

      expect(result.job.priority).to eq("medium")
      expect(result.job.agent_provider).to eq(repository.effective_agent_provider)
    end

    it "leaves delivery_track nil by default" do
      result = described_class.call(user: user, repository: repository, prompt: "Investigate something.")

      expect(result.job.delivery_track).to be_nil
    end

    it "persists an explicit delivery_track" do
      result = described_class.call(
        user: user,
        repository: repository,
        prompt: "Investigate something.",
        delivery_track: "hotfix"
      )

      expect(result.job.delivery_track).to eq("hotfix")
    end

    it "fails without creating a Job when the prompt is blank" do
      expect {
        result = described_class.call(user: user, repository: repository, prompt: "  ")
        expect(result).not_to be_success
        expect(result.error).to match(/prompt is required/)
      }.not_to change(Job, :count)
    end
  end
end
