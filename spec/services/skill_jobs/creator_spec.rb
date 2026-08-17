require "rails_helper"

RSpec.describe SkillJobs::Creator do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  describe ".call" do
    it "creates a direct Job carrying skill_name/skill_args and dispatches a skill Workflow" do
      result = described_class.call(
        user: user,
        repository: repository,
        name: "investigate",
        args: { "question" => "What does the widget do?" }
      )

      expect(result).to be_success
      job = result.job
      expect(job.kind).to eq("direct")
      expect(job.skill_name).to eq("investigate")
      expect(job.skill_args).to eq({ "question" => "What does the widget do?" })
      expect(job.issue_number).to be_nil

      workflow = job.workflows.last
      expect(workflow.trigger_kind).to eq("skill")
      expect(workflow.artifact("skill_name")).to eq("investigate")
      expect(workflow.artifact("skill_args")).to eq({ "question" => "What does the widget do?" })
    end

    it "defaults to medium priority and the repository's effective agent provider" do
      result = described_class.call(user: user, repository: repository, name: "investigate", args: { "question" => "x" })

      expect(result.job.priority).to eq("medium")
      expect(result.job.agent_provider).to eq(repository.effective_agent_provider)
    end

    it "fails without creating a Job when the skill name doesn't resolve" do
      expect {
        result = described_class.call(user: user, repository: repository, name: "does-not-exist", args: {})
        expect(result).not_to be_success
        expect(result.error).to match(/could not resolve skill/)
      }.not_to change(Job, :count)
    end

    it "fails without creating a Job when required args are missing" do
      expect {
        result = described_class.call(user: user, repository: repository, name: "investigate", args: {})
        expect(result).not_to be_success
        expect(result.error).to match(/question/)
      }.not_to change(Job, :count)
    end

    it "fails without creating a Job when submitted args include an undeclared key" do
      expect {
        result = described_class.call(
          user: user,
          repository: repository,
          name: "investigate",
          args: { "question" => "x", "bogus" => "y" }
        )
        expect(result).not_to be_success
        expect(result.error).to match(/bogus/)
      }.not_to change(Job, :count)
    end
  end
end
