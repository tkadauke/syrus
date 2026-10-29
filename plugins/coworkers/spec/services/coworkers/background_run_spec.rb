require "rails_helper"

RSpec.describe "Coworker background runs" do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-background",
      workspace_repo: repository.remote_url
    )
  end
  let(:main_chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:job) do
    Job.create!(
      user: owner, repository: repository, kind: "coworker_task", priority: "low",
      origin: "coworkers", origin_id: coworker.id.to_s,
      issue_title: "Review the calendar", issue_body: "Review tomorrow's calendar."
    )
  end

  before do
    PluginRecord.find_or_create_by!(name: "coworkers").update!(enabled: true, disableable: true)
    Coworkers::Chat.create!(coworker: coworker, chat_session: main_chat, role: "main")
  end

  it "builds prepare, agent, post, and close steps on the coworker's home branch" do
    workflow = Coworkers::Workflow.instantiate(job: job)

    expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[prepare coworker_run post_to_chat auto_close])
    expect(workflow.artifact(WorkflowWorkspace::REQUIRED_BRANCH_ARTIFACT)).to eq("coworkers/maya-background")
  end

  it "uses a coworker mutex without taking the repository mutex" do
    definition = Coworkers::WorkDefinition.new

    expect(definition.lock_keys_for(job: job, member_jobs: [ job ])).to contain_exactly(
      "job:#{job.id}", "coworker:#{coworker.id}"
    )
  end

  it "defers the agent phase while the main chat has a turn in flight" do
    workflow = Coworkers::Workflow.instantiate(job: job)
    unit = instance_double(WorkUnit, workflow: workflow, member_jobs: [ job ])
    step = workflow.steps.find_by!(kind: "coworker_run")
    main_chat.update!(turn_in_flight: true)

    blocked = Coworkers::TurnAvailabilityGate.call(unit, step: step)
    expect(blocked).to be_blocked
    expect(blocked.reason).to eq("coworker_turn_in_flight")
    expect(blocked.details).to include("coworker_id" => coworker.id, "chat_session_id" => main_chat.id)

    main_chat.update!(turn_in_flight: false)
    expect(Coworkers::TurnAvailabilityGate.call(unit, step: step)).to be_pass
  end

  it "gives the run only granted coworker tools, queues live confirmations, and omits interactive tools" do
    coworker.grants.create!(capability: "syrus.read_jobs", approval_policy: "confirm")
    coworker.grants.create!(capability: "chat.message_owner", approval_policy: "auto")
    workflow = Coworkers::Workflow.instantiate(job: job)
    step = workflow.steps.find_by!(kind: "coworker_run")
    run = Run.new(job: job, user: owner, step: step, trigger_kind: "coworker_run", agent_provider: "codex")

    context = McpToolContext.from_run(run)
    names = McpToolPolicy.for(context).map { |tool| McpToolRegistry.tool_name_for(tool) }

    expect(context).to have_attributes(role: AgentRole::COWORKER, interactive: false)
    expect(context.capability_approval_policies["syrus.read_jobs"]).to eq("queue")
    expect(names).to include("list_jobs", "search_jobs", "read_job")
    expect(names).not_to include("ask_user_question", "suggest_next_step", "force_fail_job", "run_command")
    expect(Mcp::Tools::ReadJobTool.call(job_id: job.id, server_context: { run: run })).not_to be_error
  end

  it "posts a completed result to the main chat without triggering a turn" do
    workflow = Coworkers::Workflow.instantiate(job: job)
    source_step = workflow.steps.find_by!(kind: "coworker_run")
    source_run = Run.create!(job: job, user: owner, step: source_step, trigger_kind: "coworker_run", agent_provider: "codex")
    source_run.update_columns(state: "succeeded", agent_summary: "Calendar reviewed.", finished_at: Time.current)
    post_step = workflow.steps.find_by!(kind: "post_to_chat")
    post_run = Run.new(job: job, user: owner, step: post_step, trigger_kind: "coworker_run", agent_provider: "codex")

    expect { Coworkers::PostToChat.new(post_run).call }.to change(main_chat.messages, :count).by(1)
    message = main_chat.messages.order(:id).last
    expect(message).to have_attributes(role: "assistant")
    expect(message.content).to include("text" => "Calendar reviewed.")
    expect(message.content.fetch("background_run")).to include("run_id" => source_run.id, "state" => "succeeded")
    expect(main_chat.reload).not_to be_turn_in_flight
  end

  it "posts a failure and closes the infrastructure Job when the agent step fails" do
    workflow = Coworkers::Workflow.instantiate(job: job)
    source_step = workflow.steps.find_by!(kind: "coworker_run")
    source_step.update_columns(state: "failed")
    source_run = Run.create!(job: job, user: owner, step: source_step, trigger_kind: "coworker_run", agent_provider: "codex")
    source_run.update_columns(state: "failed", finished_at: Time.current)

    expect { Coworkers::Workflow.after_fail(workflow) }.to change(main_chat.messages, :count).by(1)

    expect(main_chat.messages.order(:id).last.content.fetch("background_run")).to include(
      "run_id" => source_run.id, "state" => "failed"
    )
    expect(job.reload).to have_attributes(state: "closed", closure_reason: "coworker_task")
  end
end
