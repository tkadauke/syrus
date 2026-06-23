require "rails_helper"

RSpec.describe App::JobDetailPayload do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def payload_for(job)
    described_class.build(job: job, user: user)
  end

  describe "#test_plan_json" do
    it "returns nil when the job has no workflows" do
      job = Factories.job_record(repository: repo)

      expect(payload_for(job)[:test_plan]).to be_nil
    end

    it "returns the test plan artifact in a stable top-level shape" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        artifacts: {
          "test_plan" => {
            "steps" => [ "Run bin/rspec spec/services/app/job_detail_payload_spec.rb", "Run bin/test-react" ],
            "notes" => "Check the Summary tab."
          }
        }
      )

      expect(payload_for(job)[:test_plan]).to eq(
        workflow_id: workflow.id,
        steps: [ "Run bin/rspec spec/services/app/job_detail_payload_spec.rb", "Run bin/test-react" ],
        notes: "Check the Summary tab."
      )
    end

    it "picks the latest workflow with a test plan artifact" do
      job = Factories.job_record(repository: repo)
      older = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        created_at: 2.hours.ago,
        artifacts: { "test_plan" => { "steps" => [ "Run old tests" ], "notes" => "old" } }
      )
      newer = Workflow.create!(
        job: job,
        trigger_kind: "retry",
        created_at: 1.hour.ago,
        artifacts: { "test_plan" => { "steps" => [ "Run new tests" ], "notes" => nil } }
      )

      expect(payload_for(job)[:test_plan]).to include(
        workflow_id: newer.id,
        steps: [ "Run new tests" ],
        notes: nil
      )
      expect(payload_for(job)[:test_plan][:workflow_id]).not_to eq(older.id)
    end

    it "treats a workflow with empty steps as absent" do
      job = Factories.job_record(repository: repo)
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        artifacts: { "test_plan" => { "steps" => [], "notes" => "Nothing to run." } }
      )

      expect(payload_for(job)[:test_plan]).to be_nil
    end
  end
end
