require "rails_helper"

RSpec.describe "Job detail classification attempts" do
  it "exposes attempt history with in-flight state and process links" do
    user = Factories.user
    repository = Factories.repository(user: user)
    job = Job.create!(user: user, repository: repository, issue_number: 42)
    finished_process = SpawnedProcess.create!(
      kind: "agent",
      command: "codex",
      hostname: "worker-1",
      started_at: 2.minutes.ago,
      finished_at: 1.minute.ago,
      outcome: "succeeded",
      job: job
    )
    job.classification_attempts.create!(
      started_at: 2.minutes.ago,
      finished_at: 1.minute.ago,
      outcome: "classified",
      decision: { classification: "valid" },
      raw_output: '{"epic_id":null}',
      spawned_process: finished_process,
      agent_provider: "codex"
    )
    job.classification_attempts.create!(
      started_at: 30.seconds.ago,
      agent_provider: "codex"
    )

    payload = App::JobDetailPayload.build(job: job, user: user)

    attempts = payload.fetch(:classification_attempts)
    expect(attempts.size).to eq(2)
    expect(attempts.first).to include(
      in_flight: true,
      outcome: nil,
      spawned_process_id: nil
    )
    expect(attempts.second).to include(
      in_flight: false,
      outcome: "classified",
      decision: { "classification" => "valid" },
      spawned_process_id: finished_process.id,
      spawned_process_path: "/admin/processes/#{finished_process.id}",
      spawned_process_outcome: "succeeded"
    )
  end
end
