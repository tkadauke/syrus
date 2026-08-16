require "rails_helper"

RSpec.describe Workflows::Base do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user) }

  describe ".solid_queue_priority" do
    Job::PRIORITIES.each do |job_priority|
      it "dispatches at the job's priority (#{job_priority}) when the workflow priority is left at the default" do
        job = Factories.job(user: user, repository: repository, priority: job_priority)
        workflow = job.workflows.first
        expect(workflow.priority).to eq("medium")

        expect(described_class.solid_queue_priority(workflow)).to eq(job.solid_queue_priority)
      end
    end

    it "overrides the job's priority when the workflow sets its own" do
      job = Factories.job(user: user, repository: repository, priority: "high")
      workflow = job.workflows.first
      workflow.update!(priority: "low")

      expect(described_class.solid_queue_priority(workflow)).to eq(Job::PRIORITY_TO_SQ["low"])
      expect(described_class.solid_queue_priority(workflow)).not_to eq(job.solid_queue_priority)
    end

    it "returns a lower integer (higher precedence) for an urgent workflow than a medium job" do
      job = Factories.job(user: user, repository: repository, priority: "medium")
      workflow = job.workflows.first
      workflow.update!(priority: "urgent")

      expect(described_class.solid_queue_priority(workflow)).to be < job.solid_queue_priority
    end
  end
end
