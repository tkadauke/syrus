require "rails_helper"

RSpec.describe Workflows::MainGrader do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user) }
  let(:job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "main_grader",
      issue_title: "main_grader:abc123",
      issue_number: nil
    )
  end
  let(:sha) { "abc123def456" }

  describe "chain" do
    it "materializes grader_fanout → grader_collect" do
      workflow = described_class.instantiate(job: job, artifacts: { "main_sha" => sha })

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[ grader_fanout grader_collect ])
      expect(workflow.trigger_kind).to eq("main_grader")
    end

    it "stores the main_sha in artifacts" do
      workflow = described_class.instantiate(job: job, artifacts: { "main_sha" => sha })

      expect(workflow.artifact("main_sha")).to eq(sha)
    end

    it "uses the default queue" do
      expect(described_class.queue_name).to eq(:default)
    end
  end

  describe ".after_success" do
    let(:workflow) { described_class.instantiate(job: job, artifacts: { "main_sha" => sha }) }

    it "updates grader_health to healthy" do
      described_class.after_success(workflow)

      expect(repository.reload.grader_health).to eq("healthy")
    end

    it "closes the anchor Job" do
      described_class.after_success(workflow)

      expect(job.reload.state).to eq("closed")
    end

    it "calls MainHealthChangedService when health transitions" do
      repository.update!(grader_health: "broken")

      expect(MainHealthChangedService).to receive(:on_health_change!).with(kind_of(Repository))
      described_class.after_success(workflow)
    end

    it "does not call MainHealthChangedService when health was already healthy and main stays healthy" do
      repository.update!(grader_health: "healthy", ci_health: "healthy")

      expect(MainHealthChangedService).not_to receive(:on_health_change!)
      described_class.after_success(workflow)
    end
  end

  describe ".after_fail" do
    let(:workflow) { described_class.instantiate(job: job, artifacts: { "main_sha" => sha }) }

    it "updates grader_health to broken" do
      described_class.after_fail(workflow)

      expect(repository.reload.grader_health).to eq("broken")
    end

    it "closes the anchor Job" do
      described_class.after_fail(workflow)

      expect(job.reload.state).to eq("closed")
    end

    it "calls MainHealthChangedService when health transitions to broken" do
      repository.update!(grader_health: "healthy", ci_health: "healthy")

      expect(MainHealthChangedService).to receive(:on_health_change!).with(kind_of(Repository))
      described_class.after_fail(workflow)
    end

    it "does not call MainHealthChangedService when grader_health was already broken" do
      repository.update!(grader_health: "broken")

      expect(MainHealthChangedService).not_to receive(:on_health_change!)
      described_class.after_fail(workflow)
    end
  end
end
