require "rails_helper"

RSpec.describe Steps::AutoClose do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) do
    Feature.find_or_create_by!(slug: "agent_insights") do |f|
      f.category = "Labs"
      f.name     = "Agent Insights"
    end.update!(enabled: true)

    Job.create!(user: user, repository: repository, kind: "agent_insight", priority: "low")
  end
  let(:workflow) { Workflows::AgentInsight.instantiate(job: job) }
  let(:step)     { workflow.steps.find_by!(kind: "auto_close") }
  let(:run)      { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:handler)  { described_class.new(run) }

  it "closes the anchor Job with reason agent_insight" do
    handler.call

    expect(job.reload.state).to eq("closed")
    expect(job.closure_reason).to eq("agent_insight")
  end

  it "is idempotent when the job is already closed" do
    run # materialize the workflow/step/run before the job closes
    job.close_with_reason!("agent_insight")

    expect { handler.call }.not_to raise_error
    expect(job.reload.state).to eq("closed")
  end

  it "raises instead of silently succeeding when the Job doesn't actually close" do
    # Regression guard for JOB-3302: if the close attempt no-ops for any
    # reason, the step must surface that as a failure rather than let the
    # Run/Step report "succeeded" while the Job stays open.
    allow_any_instance_of(Job).to receive(:may_close?).and_return(false)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /not closed/)
    expect(job.reload.state).not_to eq("closed")
  end
end
