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
  let(:lifecycle) { instance_double(Coworkers::ChatWorkspaceLifecycle, finalize_background!: :merged) }
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
    allow(Coworkers::ChatWorkspaceLifecycle).to receive(:new).with(main_chat).and_return(lifecycle)
  end

  it "builds prepare, agent, post, and close steps on the coworker's home branch" do
    workflow = Coworkers::Workflow.instantiate(job: job)

    expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[prepare coworker_run post_to_chat auto_close])
    expect(workflow.artifact(WorkflowWorkspace::REQUIRED_BRANCH_ARTIFACT)).to eq("coworkers/maya-background")
  end

  it "runs prepare through a workspace pinned to the coworker's home branch" do
    workflow = Coworkers::Workflow.instantiate(job: job)
    step = workflow.steps.find_by!(kind: "prepare")
    run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
    workspace = instance_double(WorkflowWorkspace, setup: nil, path: Pathname.new(Dir.mktmpdir("coworker-prepare")))
    handler = Steps::Prepare.new(run)
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(WorkerCapabilities).to receive(:environment_fingerprint_metadata).and_return({})

    expect { handler.call }.not_to raise_error
    expect(workspace).to have_received(:setup)
    expect(workflow.reload.artifact(WorkflowWorkspace::REQUIRED_BRANCH_ARTIFACT)).to eq("coworkers/maya-background")
  ensure
    FileUtils.rm_rf(workspace.path) if workspace
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

  it "queues confirm and queue mutations from unattended runs and replays an approval in its run context" do
    coworker.grants.create!(capability: "syrus.propose_job", approval_policy: "confirm")
    workflow = Coworkers::Workflow.instantiate(job: job)
    step = workflow.steps.find_by!(kind: "coworker_run")
    run = Run.create!(job: job, user: owner, step: step, trigger_kind: "coworker_run", agent_provider: "codex")
    arguments = {
      repo: repository.slug, title: "Prepare the report", description: "Create the requested report.",
      planned_execution: { capabilities: { os: [ "linux" ] } }
    }

    response = Mcp::Tools::AuthorizationSupport.pending_coworker_approval(
      Mcp::Tools::ProposeJobTool, { run: run }, arguments
    )
    action = main_chat.pending_actions.find(JSON.parse(response.content.first[:text]).fetch("pending_action_id"))

    expect(response).not_to be_error
    expect(action).to be_pending
    expect(action.payload).to include(
      "run_id" => run.id, "tool_name" => "propose_job", "approval_policy" => "queue", "approval_inbox" => true,
      "arguments" => include("title" => "Prepare the report")
    )
    expect { action.confirm!(user: owner) }.to change(main_chat.proposals, :count).by(1)
    expect(action.reload).to be_confirmed
    expect(action.payload.fetch("tool_result")).to include("Prepare the report")
    expect(main_chat.messages.where(role: "system").order(:id).last.content.fetch("text"))
      .to include("Coworker tool approved and executed", "Prepare the report")

    coworker.grants.find_by!(capability: "syrus.propose_job").update!(approval_policy: "queue")
    queued = Mcp::Tools::AuthorizationSupport.pending_coworker_approval(
      Mcp::Tools::ProposeJobTool, { run: run }, arguments.merge(title: "Queue the report")
    )
    queued_action = main_chat.pending_actions.find(JSON.parse(queued.content.first[:text]).fetch("pending_action_id"))
    expect(queued_action).to be_pending
    expect(queued_action.payload).to include("approval_policy" => "queue", "approval_inbox" => true)
    expect(JSON.parse(queued.content.first[:text])).to include("approval_policy" => "queue")

    expired = main_chat.pending_actions.create!(
      action: "coworker_tool_call", requested_by: "agent",
      payload: { "tool_name" => "propose_job", "arguments" => arguments.stringify_keys, "run_id" => -1 }
    )
    expect { expired.confirm!(user: owner) }.to raise_error(ArgumentError, "originating run is no longer available")
    expect(expired.reload).to be_failed
    expect(expired.execution_error).to include("originating run is no longer available")
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


  it "posts a result without clearing an owner turn that started while the run was finishing" do
    workflow = Coworkers::Workflow.instantiate(job: job)
    source_step = workflow.steps.find_by!(kind: "coworker_run")
    source_run = Run.create!(job: job, user: owner, step: source_step, trigger_kind: "coworker_run", agent_provider: "codex")
    source_run.update_columns(state: "succeeded", started_at: 5.seconds.ago, finished_at: Time.current, cost_usd: 0.25)
    owner_message = main_chat.messages.create!(role: "user", content: { "text" => "Meanwhile" }, skip_turn_trigger: true)
    main_chat.update_columns(turn_in_flight: true, current_turn_message_id: owner_message.id)
    post_run = Run.new(job: job, user: owner, step: workflow.steps.find_by!(kind: "post_to_chat"), trigger_kind: "coworker_run", agent_provider: "codex")

    Coworkers::PostToChat.new(post_run).call

    expect(main_chat.reload).to be_turn_in_flight
    expect(main_chat.messages.last.content.fetch("background_run")).to include(
      "duration_seconds" => 5.0, "cost_usd" => "0.25", "merge_state" => "merged"
    )
  end

  it "posts a failure and closes the infrastructure Job when the agent step fails" do
    workflow = Coworkers::Workflow.instantiate(job: job)
    source_step = workflow.steps.find_by!(kind: "coworker_run")
    source_step.update_columns(state: "failed")
    source_run = Run.create!(job: job, user: owner, step: source_step, trigger_kind: "coworker_run", agent_provider: "codex")
    source_run.update_columns(state: "failed", finished_at: Time.current)

    expect { Coworkers::Workflow.after_fail(workflow) }.to change(main_chat.messages, :count).by(1)

    expect(main_chat.messages.order(:id).last.content.fetch("background_run")).to include(
      "run_id" => source_run.id, "state" => "failed", "merge_state" => "merged"
    )
    expect(lifecycle).to have_received(:finalize_background!).with(
      path: StepWorkspace.for(source_step, run: source_run).path,
      workflow: workflow
    )
    expect(job.reload).to have_attributes(state: "closed", closure_reason: "coworker_task")
  end

  it "auto-pauses the originating schedule after consecutive failures" do
    task = ScheduledTasks::Task.create!(
      user: owner, repository: repository, name: "Daily review", prompt: "Review it.",
      kind: "cron", cron_expression: "0 9 * * *", minute_offset: 5, pr_pileup_policy: "skip"
    )
    task.update_columns(consecutive_failure_count: AppSetting.max_job_failures - 1)
    job.update!(scheduled_task_id: task.id)
    workflow = Coworkers::Workflow.instantiate(job: job)
    workflow.steps.find_by!(kind: "coworker_run").update_columns(state: "failed")

    Coworkers::Workflow.after_fail(workflow)

    expect(task.reload).to be_auto_paused
  end
end
