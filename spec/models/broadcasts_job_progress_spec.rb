require "rails_helper"

RSpec.describe BroadcastsJobProgress do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "queued") }

  before do
    allow(AppUserChannel).to receive(:broadcast_to)
  end

  it "broadcasts a job update when a Workflow is created" do
    workflow = Workflow.create!(job: job, trigger_kind: "initial")

    expect(AppUserChannel).to have_received(:broadcast_to).with(
      user,
      hash_including(
        "type" => "job.updated",
        "resource" => "job",
        "id" => job.id,
        "changed" => include("workflow.created", "id", "job_id", "trigger_kind")
      )
    )
    expect(workflow).to be_persisted
  end

  it "broadcasts a job update when a Step changes progress state" do
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    step = Step.create!(workflow: workflow, kind: "implement", position: 0)
    RSpec::Mocks.space.proxy_for(AppUserChannel).reset
    allow(AppUserChannel).to receive(:broadcast_to)

    step.start!
    step.save!

    expect(AppUserChannel).to have_received(:broadcast_to).with(
      user,
      hash_including(
        "type" => "job.updated",
        "resource" => "job",
        "id" => job.id,
        "changed" => include("step.updated", "state", "started_at")
      )
    )
  end

  it "broadcasts a job update when a Run changes progress state" do
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    step = Step.create!(workflow: workflow, kind: "implement", position: 0)
    run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "running")
    RSpec::Mocks.space.proxy_for(AppUserChannel).reset
    allow(AppUserChannel).to receive(:broadcast_to)

    run.succeed!
    run.save!

    expect(AppUserChannel).to have_received(:broadcast_to).with(
      user,
      hash_including(
        "type" => "job.updated",
        "resource" => "job",
        "id" => job.id,
        "changed" => include("run.updated", "state", "finished_at")
      )
    )
  end

  it "does not broadcast for heartbeat-only Run updates" do
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    step = Step.create!(workflow: workflow, kind: "implement", position: 0)
    run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "running")
    RSpec::Mocks.space.proxy_for(AppUserChannel).reset
    allow(AppUserChannel).to receive(:broadcast_to)

    run.update!(last_heartbeat_at: Time.current)

    expect(AppUserChannel).not_to have_received(:broadcast_to)
  end
end
