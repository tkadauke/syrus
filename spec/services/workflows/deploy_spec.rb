require "rails_helper"

RSpec.describe Workflows::Deploy do
  let(:job) { Factories.job }

  it "declares trigger_kind deploy" do
    expect(described_class.trigger_kind).to eq("deploy")
  end

  describe ".steps_for" do
    it "chains prepare then deploy" do
      expect(described_class.steps_for(job)).to eq(%w[prepare deploy])
    end
  end

  describe ".instantiate" do
    it "materializes the prepare -> deploy chain template" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.trigger_kind).to eq("deploy")
      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[prepare deploy])
      expect(workflow.chain_template).to eq([
        { "type" => "step", "kind" => "prepare" },
        { "type" => "step", "kind" => "deploy" }
      ])
    end

    it "omits prepare when the job has a prepare_skip_reason" do
      allow(job).to receive(:prepare_skip_reason).and_return("syrus-skip-prepare label")

      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[deploy])
    end
  end

  describe "anchor Job closure" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }
    let(:anchor_job) do
      Job.create!(
        user: user,
        repository: repository,
        kind: "deploy",
        issue_title: "deploy:abc123",
        issue_number: nil,
        state: "running"
      )
    end

    it ".after_success closes a continuous-deploy anchor Job" do
      workflow = described_class.instantiate(job: anchor_job, artifacts: { "deploy_sha" => "abc123" })

      expect { described_class.after_success(workflow) }
        .to change { anchor_job.reload.state }.from("running").to("closed")

      expect(anchor_job.closure_reason).to eq(Job::DEPLOY_CLOSURE_REASON)
    end

    it ".after_fail closes a continuous-deploy anchor Job" do
      workflow = described_class.instantiate(job: anchor_job, artifacts: { "deploy_sha" => "abc123" })

      expect { described_class.after_fail(workflow) }
        .to change { anchor_job.reload.state }.from("running").to("closed")

      expect(anchor_job.closure_reason).to eq(Job::DEPLOY_CLOSURE_REASON)
    end

    it "does not close an ordinary Job used for a manual deploy" do
      manual_job = Factories.job_record(repository: repository, state: "approved")
      workflow = described_class.instantiate(job: manual_job)

      expect { described_class.after_success(workflow) }
        .not_to change { manual_job.reload.state }

      expect { described_class.after_fail(workflow) }
        .not_to change { manual_job.reload.state }
    end
  end
end
