require "rails_helper"

RSpec.describe SpawnedProcessPruneJob do
  def fixture(**overrides)
    SpawnedProcess.create!({
      kind: "agent",
      command: "claude --print",
      hostname: "host",
      started_at: 8.days.ago
    }.merge(overrides))
  end

  it "deletes finished rows older than the retention window" do
    old = fixture(finished_at: 8.days.ago, outcome: "succeeded", exit_status: 0)
    fresh = fixture(finished_at: 1.day.ago, outcome: "succeeded", exit_status: 0)
    running = fixture(started_at: 1.minute.ago)

    described_class.perform_now

    expect(SpawnedProcess.where(id: old.id)).to be_empty
    expect(SpawnedProcess.where(id: [ fresh.id, running.id ]).count).to eq(2)
  end

  # command_spans.spawned_process_id carries a real foreign key, and delete_all
  # skips the association's `dependent: :nullify`. In production this aborted
  # every sweep with ActiveRecord::InvalidForeignKey, so the table never got
  # pruned at all.
  context "when a retained command span still references a prunable process" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }
    let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }

    def span_for(spawned_process, sequence:)
      workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", state: "running")
      step = Step.create!(workflow: workflow, kind: "grader", position: 1, state: "succeeded", details: { "name" => "rspec" })
      run = Run.create!(job: job, user: user, step: step, trigger_kind: "initial", state: "succeeded")

      CommandSpan.create!(
        job: job,
        workflow: workflow,
        step: step,
        run: run,
        spawned_process: spawned_process,
        sequence: sequence,
        name: "rspec",
        command_excerpt: "bin/rspec",
        hostname: "host",
        started_at: 8.days.ago,
        metadata: {}
      )
    end

    it "detaches the spans and still deletes the expired processes" do
      old = fixture(finished_at: 8.days.ago, outcome: "succeeded", exit_status: 0)
      span = span_for(old, sequence: 1)

      expect { described_class.perform_now }.not_to raise_error

      expect(SpawnedProcess.where(id: old.id)).to be_empty
      expect(span.reload.spawned_process_id).to be_nil
    end

    it "leaves spans attached to processes inside the retention window" do
      fresh = fixture(finished_at: 1.day.ago, outcome: "succeeded", exit_status: 0)
      span = span_for(fresh, sequence: 2)

      described_class.perform_now

      expect(span.reload.spawned_process_id).to eq(fresh.id)
    end
  end
end
