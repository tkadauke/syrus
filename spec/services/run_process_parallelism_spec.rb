require "rails_helper"

RSpec.describe RunProcessParallelism do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:workflow) { Workflows::Initial.instantiate(job: job, agent_provider: "codex") }
  let(:step) { Step.create!(workflow: workflow, kind: "grader", position: 99, details: { "name" => "rspec" }) }
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider) }

  before do
    allow(described_class).to receive(:host_capacity).and_return(6)
  end

  it "reserves headroom and caps one grader's process fanout" do
    expect(described_class.for(run: run, hostname: "worker-a")).to eq(6)
  end

  it "divides the CPU budget among active local graders" do
    2.times do
      other_run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
      SpawnedProcess.create!(
        run: other_run,
        workflow: workflow,
        kind: "grader",
        command: "bundle exec rspec",
        hostname: "worker-a",
        started_at: Time.current
      )
    end

    expect(described_class.for(run: run, hostname: "worker-a")).to eq(2)
  end

  it "does not count completed or remote grader processes" do
    completed_run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
    SpawnedProcess.create!(
      run: completed_run,
      workflow: workflow,
      kind: "grader",
      command: "bundle exec rspec",
      hostname: "worker-a",
      started_at: 1.minute.ago,
      finished_at: Time.current
    )
    SpawnedProcess.create!(
      run: completed_run,
      workflow: workflow,
      kind: "grader",
      command: "bundle exec rspec",
      hostname: "worker-b",
      started_at: Time.current
    )

    expect(described_class.for(run: run, hostname: "worker-a")).to eq(6)
  end
end
