require "rails_helper"

RSpec.describe AgentActivity::SessionSerializer do
  let(:repository) { Factories.repository(owner: "acme", name: "widgets") }

  def agent_for_run(run, outcome: nil)
    agent = Agent.find_or_create_for!(run)
    SpawnedProcess.create!(
      agent: agent,
      run: run,
      workflow: run.workflow,
      kind: "agent",
      command: "codex exec",
      hostname: "spec-host",
      started_at: run.started_at || run.created_at,
      finished_at: run.finished_at,
      outcome: outcome || (run.state == "running" ? nil : run.state)
    )
    agent
  end

  it "serializes role/label structurally from Step::Kind, not from transcript text" do
    job = Factories.job_with_run(
      repository: repository,
      issue_title: "Fix the aqueducts",
      step_attrs: { kind: "adversarial_review" },
      run_attrs: { state: "running", agent_provider: "claude", started_at: 5.minutes.ago }
    )
    run = job.runs.last
    agent = agent_for_run(run)

    payload = described_class.call(agent, transcript_path: "/api/v1/app/jobs/#{job.id}/runs/#{run.id}/artifacts")

    expect(payload).to include(
      id: agent.id,
      state: "running",
      role_label: Step::Kind.label_for("adversarial_review"),
      agent_provider: "claude",
      transcript_path: "/api/v1/app/jobs/#{job.id}/runs/#{run.id}/artifacts"
    )
    expect(payload[:job]).to include(id: job.id, title: "Fix the aqueducts")
    expect(payload[:repository]).to eq(id: repository.id, slug: "acme/widgets")
  end

  it "builds workflow transcript paths from the requested surface scope" do
    job = Factories.job_with_run(repository: repository, run_attrs: { state: "running" })
    run = job.runs.last
    agent = agent_for_run(run)

    payload = described_class.call(agent, scope: :admin)

    expect(payload[:transcript_path]).to eq("/api/v1/app/admin/agent_activity/sessions/#{run.id}/artifacts")
    expect(payload[:chat_path]).to be_nil
  end

  it "serializes chat sessions with a live-chat deep link and no transcript drawer path" do
    chat = ChatSession.create!(user: repository.user, repository: repository, mode: "coding", chat_provider: "codex")
    agent = Agent.find_or_create_for!(chat)
    SpawnedProcess.create!(
      agent: agent,
      chat_session: chat,
      kind: "agent",
      command: "codex exec",
      hostname: "spec-host",
      started_at: 2.minutes.ago,
      finished_at: nil,
      outcome: nil
    )

    payload = described_class.call(agent)

    expect(payload).to include(
      state: "running",
      role_label: "Coding",
      agent_provider: "codex",
      transcript_path: nil,
      chat_path: "/chats/#{chat.id}"
    )
    expect(payload[:repository]).to eq(id: repository.id, slug: "acme/widgets")
  end

  it "omits row fields that have no feed consumer" do
    job = Factories.job_with_run(repository: repository, run_attrs: { state: "succeeded" })
    payload = described_class.call(agent_for_run(job.runs.last))

    expect(payload).not_to include(:slug, :step_kind, :role, :agent_outcome, :finished_at, :created_at, :workflow_id, :trigger_kind)
  end

  it "computes duration from started_at to finished_at, or to now while still running" do
    job = Factories.job_with_run(
      repository: repository,
      run_attrs: { state: "succeeded", started_at: 10.minutes.ago, finished_at: 4.minutes.ago }
    )
    run = job.runs.last
    agent = agent_for_run(run)

    payload = described_class.call(agent, transcript_path: "x")

    expect(payload[:duration_seconds]).to be_within(2).of(6.minutes.to_i)
  end

  it "surfaces the submitted outcome text and verdict" do
    job = Factories.job_with_run(
      repository: repository,
      step_attrs: { kind: "visual_review", iteration: 1 },
      run_attrs: { state: "succeeded" }
    )
    run = job.runs.last
    agent = agent_for_run(run)
    run.workflow.set_artifact!("visual_review_iterations", [ { "iteration" => 1, "critique" => "Layout shifted.", "verdict" => "needs_work" } ])

    payload = described_class.call(agent, transcript_path: "x")

    expect(payload[:outcome_summary]).to eq("Layout shifted.")
    expect(payload[:outcome_verdict]).to eq("needs_work")
  end
end
