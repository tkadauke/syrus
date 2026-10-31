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
    owner_message = main_chat.messages.create!(role: "user", content: { "text" => "Meanwhile" }, skip_turn_trigger: true)
    main_chat.update!(turn_in_flight: true, current_turn_message_id: owner_message.id)

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

  it "reads only the coworker's own and explicitly shared chats from a run context" do
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE chat_message_fts
      USING fts5(content, user_id UNINDEXED, chat_session_id UNINDEXED, chat_message_id UNINDEXED, role UNINDEXED, created_at UNINDEXED, tokenize = 'porter unicode61')
    SQL
    SearchRecord.connection.execute("CREATE TABLE IF NOT EXISTS chat_search_metadata (key TEXT PRIMARY KEY, value TEXT)")
    coworker.grants.create!(capability: "chats.read_shared", approval_policy: "auto")
    shared_chat = ChatSession.create!(user: owner, title: "Shared feedback")
    private_chat = ChatSession.create!(user: owner, title: "Owner private")
    ChatShare.create!(chat_session: shared_chat, target: coworker, shared_by_user: owner)
    own_message = main_chat.messages.create!(role: "user", content: { "text" => "background-own-needle" })
    shared_message = shared_chat.messages.create!(role: "user", content: { "text" => "background-shared-needle" })
    private_message = private_chat.messages.create!(role: "user", content: { "text" => "background-private-needle" })
    [ own_message, shared_message, private_message ].each { |message| ChatMessageSearchIndex.insert(message) }
    workflow = Coworkers::Workflow.instantiate(job: job)
    run = Run.create!(job: job, user: owner, step: workflow.steps.find_by!(kind: "coworker_run"),
      trigger_kind: "coworker_run", agent_provider: "codex")
    context = { run: run }

    listed = JSON.parse(Mcp::Tools::ListChatsTool.call(server_context: context).content.first[:text]).fetch("chats")
    expect(listed.pluck("id")).to contain_exactly(main_chat.id, shared_chat.id)

    searched = JSON.parse(
      Mcp::Tools::SearchChatsTool.call(server_context: context, query: "background").content.first[:text]
    ).fetch("results")
    expect(searched.pluck("chat_session_id")).to contain_exactly(main_chat.id, shared_chat.id)

    expect(Mcp::Tools::ReadChatMessagesTool.call(server_context: context, chat_session_id: main_chat.id)).not_to be_error
    expect(Mcp::Tools::ReadChatMessagesTool.call(server_context: context, chat_session_id: shared_chat.id)).not_to be_error
    expect(Mcp::Tools::ReadChatMessagesTool.call(server_context: context, chat_session_id: private_chat.id)).to be_error
  end

  it "calls every tool exposed to an unattended coworker once without raising from run-only context" do
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE chat_message_fts
      USING fts5(content, user_id UNINDEXED, chat_session_id UNINDEXED, chat_message_id UNINDEXED, role UNINDEXED, created_at UNINDEXED, tokenize = 'porter unicode61')
    SQL
    SearchRecord.connection.execute("CREATE TABLE IF NOT EXISTS chat_search_metadata (key TEXT PRIMARY KEY, value TEXT)")
    McpToolRegistry.entries(surface: :coworker).map(&:capability).compact.uniq.each do |capability|
      attributes = { capability: capability, approval_policy: "queue" }
      attributes[:scope] = [ repository.id ] if capability.to_s == "code.read"
      coworker.grants.create!(attributes)
    end
    workflow = Coworkers::Workflow.instantiate(job: job)
    run = Run.create!(job: job, user: owner, step: workflow.steps.find_by!(kind: "coworker_run"),
      trigger_kind: "coworker_run", agent_provider: "codex")
    arguments = {
      "search_jobs" => { query: "nothing" },
      "read_job" => { job_id: job.id },
      "propose_job" => { repo: repository.slug, title: "Audit proposal", description: "Audit only." },
      "propose_epic_with_jobs" => { epic: { slug: "audit-epic", title: "Audit", description: "Audit only." }, jobs: [] },
      "search_chats" => { query: "nothing" },
      "read_chat_messages" => { chat_session_id: main_chat.id }
    }

    context = McpToolContext.from_run(run)
    exposed = McpToolPolicy.for(context)
    expect(exposed).not_to be_empty
    exposed.each do |tool|
      name = McpToolRegistry.tool_name_for(tool)
      expect { tool.call(server_context: { run: run }, **arguments.fetch(name, {})) }.not_to raise_error
    end
  end

  it "dispatches chat listing and search through the scheduled-run authorization boundary" do
    coworker.grants.create!(capability: "chats.read_shared", approval_policy: "auto")
    own_side_chat = ChatSession.create!(user: owner, title: "Coworker side chat")
    Coworkers::Chat.create!(coworker: coworker, chat_session: own_side_chat, role: "side")
    shared_chat = ChatSession.create!(user: owner, title: "Shared owner chat")
    ChatShare.create!(chat_session: shared_chat, target: coworker, shared_by_user: owner)
    ChatSession.create!(user: owner, title: "Unshared owner chat")
    other_coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Other", handle: "other-background",
      workspace_repo: repository.remote_url
    )
    other_chat = ChatSession.create!(user: owner, title: "Other coworker chat")
    Coworkers::Chat.create!(coworker: other_coworker, chat_session: other_chat, role: "main")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_search_metadata")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE chat_message_fts
      USING fts5(content, user_id UNINDEXED, chat_session_id UNINDEXED, chat_message_id UNINDEXED, role UNINDEXED, created_at UNINDEXED)
    SQL
    SearchRecord.connection.execute("CREATE TABLE chat_search_metadata (key TEXT PRIMARY KEY, value TEXT)")
    [ main_chat, own_side_chat, shared_chat, other_chat ].each do |session|
      message = session.messages.create!(role: "user", content: { "text" => "scheduled needle" })
      ChatMessageSearchIndex.insert(message)
    end
    workflow = Coworkers::Workflow.instantiate(job: job)
    run = Run.create!(
      job: job, user: owner, step: workflow.steps.find_by!(kind: "coworker_run"),
      trigger_kind: "coworker_run", agent_provider: "codex"
    )
    worker_id = "coworker-worker"
    token = McpInvocationContext.issue_for_run(run, worker_id: worker_id, provider: "codex")
    raw_context = {
      identity: { worker_id: worker_id }, workflow_role: AgentRole::COWORKER,
      _meta: { PersistentMcpDaemon::INVOCATION_CONTEXT_META_KEY => token }
    }

    list_tool = PersistentMcpDaemon::WorkflowToolDispatch.wrap(Mcp::Tools::ListChatsTool)
    list_response = list_tool.call(server_context: raw_context, page: 1, per_page: 10)
    listed_ids = JSON.parse(list_response.content.first[:text]).fetch("chats").pluck("id")
    expect(list_response).not_to be_error
    expect(listed_ids).to contain_exactly(main_chat.id, own_side_chat.id, shared_chat.id)

    search_tool = PersistentMcpDaemon::WorkflowToolDispatch.wrap(Mcp::Tools::SearchChatsTool)
    search_response = search_tool.call(server_context: raw_context, query: "needle", limit: 7)

    expect(search_response).not_to be_error
    expect(JSON.parse(search_response.content.first[:text]).fetch("results").pluck("chat_session_id"))
      .to match_array(listed_ids)

    empty_response = search_tool.call(server_context: raw_context, query: "missing", limit: 7)
    expect(JSON.parse(empty_response.content.first[:text])).to eq(
      "results" => [], "message" => "No matching messages found."
    )
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

  it "posts the card and wakes the coworker for one full unattended chat turn" do
    task = ScheduledTasks::Task.create!(
      user: owner, repository: repository, coworker_id: coworker.id, name: "Daily review",
      prompt: "Review today's calendar.", kind: "cron", schedule_input: "Every day at 9:00 AM",
      pr_pileup_policy: "skip", after_run: "wake"
    )
    job.update!(scheduled_task_id: task.id)
    coworker.grants.create!(capability: "syrus.propose_job", approval_policy: "confirm")
    workflow = Coworkers::Workflow.instantiate(job: job)
    source_run = Run.create!(job: job, user: owner, step: workflow.steps.find_by!(kind: "coworker_run"), trigger_kind: "coworker_run", agent_provider: "codex")
    source_run.update_columns(state: "succeeded", agent_summary: "Calendar reviewed.", started_at: 5.seconds.ago, finished_at: Time.current, cost_usd: 0.25)
    post_run = Run.new(job: job, user: owner, step: workflow.steps.find_by!(kind: "post_to_chat"), trigger_kind: "coworker_run", agent_provider: "codex")

    expect { Coworkers::PostToChat.new(post_run).call }
      .to change(main_chat.messages, :count).by(2)
      .and have_enqueued_job(ChatTurnJob)

    wake = main_chat.messages.order(:id).last
    expect(wake).to have_attributes(role: "system")
    expect(wake.content.fetch("internal_prompt")).to include(
      "follow-up to your scheduled run", "Daily review", "Review today's calendar.",
      "Calendar reviewed.", "Run ID: #{source_run.id}", "Duration: 5.0 seconds", "Cost: $0.25",
      "Do not repeat the whole background-run card", "Do not start or fire another scheduled run"
    )
    expect(main_chat.reload).to be_turn_in_flight
    expect(McpToolContext.from_chat_session(main_chat)).to have_attributes(role: AgentRole::COWORKER_CHAT, interactive: false)
    expect(McpToolPolicy.for(McpToolContext.from_chat_session(main_chat)).map { |tool| McpToolRegistry.tool_name_for(tool) }).to include("propose_job")
  end

  it "posts only the card when the schedule is quiet" do
    task = ScheduledTasks::Task.create!(
      user: owner, repository: repository, coworker_id: coworker.id, name: "Quiet review",
      prompt: "Review quietly.", kind: "cron", schedule_input: "Every day at 9:00 AM",
      pr_pileup_policy: "skip", after_run: "quiet"
    )
    job.update!(scheduled_task_id: task.id)
    workflow = Coworkers::Workflow.instantiate(job: job)
    source_run = Run.create!(job: job, user: owner, step: workflow.steps.find_by!(kind: "coworker_run"), trigger_kind: "coworker_run", agent_provider: "codex")
    source_run.update_columns(state: "succeeded", agent_summary: "Done.", finished_at: Time.current)
    post_run = Run.new(job: job, user: owner, step: workflow.steps.find_by!(kind: "post_to_chat"), trigger_kind: "coworker_run", agent_provider: "codex")

    expect { Coworkers::PostToChat.new(post_run).call }.to change(main_chat.messages, :count).by(1)
    expect(main_chat.chat_queued_messages).to be_empty
    expect(main_chat.reload).not_to be_turn_in_flight
  end

  it "queues one wake per run while another turn is in flight" do
    task = ScheduledTasks::Task.create!(
      user: owner, repository: repository, coworker_id: coworker.id, name: "Busy review",
      prompt: "Review it.", kind: "cron", schedule_input: "Every day at 9:00 AM",
      pr_pileup_policy: "skip", after_run: "wake"
    )
    job.update!(scheduled_task_id: task.id)
    workflow = Coworkers::Workflow.instantiate(job: job)
    source_run = Run.create!(job: job, user: owner, step: workflow.steps.find_by!(kind: "coworker_run"), trigger_kind: "coworker_run", agent_provider: "codex")
    source_run.update_columns(state: "succeeded", agent_summary: "Done.", finished_at: Time.current)
    post_run = Run.new(job: job, user: owner, step: workflow.steps.find_by!(kind: "post_to_chat"), trigger_kind: "coworker_run", agent_provider: "codex")
    owner_message = main_chat.messages.create!(role: "user", content: { "text" => "Meanwhile" }, skip_turn_trigger: true)
    main_chat.update!(turn_in_flight: true, current_turn_message_id: owner_message.id)

    2.times { Coworkers::PostToChat.new(post_run).call }

    expect(main_chat.chat_queued_messages.pending.count).to eq(1)
    expect(main_chat.messages.where(role: "system")).to be_empty
    expect(source_run.reload.coworker_wake_enqueued_at).to be_present
  end

  it "resumes wake delivery when the result card was recorded before the wake was queued" do
    task = ScheduledTasks::Task.create!(
      user: owner, repository: repository, coworker_id: coworker.id, name: "Resumable review",
      prompt: "Review it.", kind: "cron", schedule_input: "Every day at 9:00 AM",
      pr_pileup_policy: "skip", after_run: "wake"
    )
    job.update!(scheduled_task_id: task.id)
    workflow = Coworkers::Workflow.instantiate(job: job)
    source_run = Run.create!(job: job, user: owner, step: workflow.steps.find_by!(kind: "coworker_run"), trigger_kind: "coworker_run", agent_provider: "codex")
    source_run.update_columns(state: "succeeded", agent_summary: "Done.", finished_at: Time.current)
    result = main_chat.messages.create!(role: "assistant", content: { "text" => "Done." }, skip_turn_trigger: true)
    workflow.set_artifact!(Coworkers::PostToChat::MESSAGE_ARTIFACT, result.id)
    workflow.set_artifact!(Coworkers::PostToChat::MERGE_ARTIFACT, "merged")
    post_run = Run.new(job: job, user: owner, step: workflow.steps.find_by!(kind: "post_to_chat"), trigger_kind: "coworker_run", agent_provider: "codex")

    expect { Coworkers::PostToChat.new(post_run).call }
      .to change(main_chat.messages, :count).by(1)
      .and have_enqueued_job(ChatTurnJob)

    expect(main_chat.messages.where(role: "assistant").count).to eq(1)
    expect(source_run.reload.coworker_wake_enqueued_at).to be_present
    expect(lifecycle).not_to have_received(:finalize_background!)
  end

  it "stores the agent's final text as the background run summary" do
    workflow = Coworkers::Workflow.instantiate(job: job)
    step = workflow.steps.find_by!(kind: "coworker_run")
    run = Run.create!(job: job, user: owner, step:, trigger_kind: "coworker_run", agent_provider: "codex")
    handler = Coworkers::RunStep.new(run)
    allow(handler).to receive(:workspace).and_return(instance_double(WorkflowWorkspace, setup: nil, path: Pathname.new(Dir.tmpdir)))
    allow(handler).to receive(:run_agent).and_return(instance_double(AgentInvocation::Result, final_text: "## Verdict\n\nAll clear."))

    handler.call

    expect(run.reload.agent_summary).to eq("## Verdict\n\nAll clear.")
  end

  it "uses the final top-level assistant transcript when the stored summary is blank" do
    workflow = Coworkers::Workflow.instantiate(job: job)
    source_step = workflow.steps.find_by!(kind: "coworker_run")
    source_run = Run.create!(job: job, user: owner, step: source_step, trigger_kind: "coworker_run", agent_provider: "codex")
    source_run.update_columns(state: "succeeded", finished_at: Time.current)
    source_run.create_provider_session!(provider: "codex", session_id: "background-session", normalized_messages: [
      { "role" => "assistant", "content" => "intermediate" },
      { "role" => "assistant", "content" => "nested", "sidechain" => true },
      { "role" => "assistant", "content" => "## Final verdict\n\nShip it." }
    ])
    post_run = Run.new(job: job, user: owner, step: workflow.steps.find_by!(kind: "post_to_chat"), trigger_kind: "coworker_run")

    Coworkers::PostToChat.new(post_run).call

    expect(main_chat.messages.last.content.fetch("background_run").fetch("summary")).to eq("## Final verdict\n\nShip it.")
  end

  it "uses fallback text only when the run produced no assistant text" do
    workflow = Coworkers::Workflow.instantiate(job: job)
    source_step = workflow.steps.find_by!(kind: "coworker_run")
    source_run = Run.create!(job: job, user: owner, step: source_step, trigger_kind: "coworker_run", agent_provider: "codex")
    source_run.update_columns(state: "succeeded", finished_at: Time.current)
    post_run = Run.new(job: job, user: owner, step: workflow.steps.find_by!(kind: "post_to_chat"), trigger_kind: "coworker_run")

    Coworkers::PostToChat.new(post_run).call

    expect(main_chat.messages.last.content.fetch("background_run").fetch("summary")).to eq("Background task completed.")
  end

  it "posts exactly one result when the post step is retried after delivery" do
    workflow = Coworkers::Workflow.instantiate(job: job)
    source_step = workflow.steps.find_by!(kind: "coworker_run")
    source_run = Run.create!(job: job, user: owner, step: source_step, trigger_kind: "coworker_run", agent_provider: "codex")
    source_run.update_columns(state: "succeeded", agent_summary: "Calendar reviewed.", finished_at: Time.current)
    post_run = Run.new(job: job, user: owner, step: workflow.steps.find_by!(kind: "post_to_chat"), trigger_kind: "coworker_run")

    2.times { Coworkers::PostToChat.new(post_run).call }

    expect(main_chat.messages.count).to eq(1)
    expect(workflow.reload.artifact(Coworkers::PostToChat::MESSAGE_ARTIFACT)).to eq(main_chat.messages.first.id)
    expect(lifecycle).to have_received(:finalize_background!).once
  end

  it "reuses the checkpointed merge outcome when delivery fails after finalization" do
    workflow = Coworkers::Workflow.instantiate(job: job)
    source_step = workflow.steps.find_by!(kind: "coworker_run")
    source_run = Run.create!(job: job, user: owner, step: source_step, trigger_kind: "coworker_run", agent_provider: "codex")
    source_run.update_columns(state: "succeeded", agent_summary: "Calendar reviewed.", finished_at: Time.current)
    post_run = Run.new(job: job, user: owner, step: workflow.steps.find_by!(kind: "post_to_chat"), trigger_kind: "coworker_run")
    attempts = 0
    allow(Coworkers::PostToChat).to receive(:post_once!).and_wrap_original do |method, **arguments|
      attempts += 1
      raise "delivery interrupted" if attempts == 1

      method.call(**arguments)
    end

    expect { Coworkers::PostToChat.new(post_run).call }.to raise_error("delivery interrupted")
    Coworkers::PostToChat.new(post_run).call

    expect(workflow.reload.artifact(Coworkers::PostToChat::MERGE_ARTIFACT)).to eq("merged")
    expect(main_chat.messages.count).to eq(1)
    expect(lifecycle).to have_received(:finalize_background!).once
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
    task = ScheduledTasks::Task.create!(
      user: owner, repository: repository, coworker_id: coworker.id, name: "Failing review",
      prompt: "Review it.", kind: "cron", schedule_input: "Every day at 9:00 AM",
      pr_pileup_policy: "skip", after_run: "wake"
    )
    job.update!(scheduled_task_id: task.id)
    workflow = Coworkers::Workflow.instantiate(job: job)
    source_step = workflow.steps.find_by!(kind: "coworker_run")
    source_step.update_columns(state: "failed")
    source_run = Run.create!(job: job, user: owner, step: source_step, trigger_kind: "coworker_run", agent_provider: "codex")
    source_run.update_columns(state: "failed", finished_at: Time.current)

    expect { Coworkers::Workflow.after_fail(workflow) }
      .to change(main_chat.messages, :count).by(2)
      .and have_enqueued_job(ChatTurnJob)

    expect(main_chat.messages.order(:id).second_to_last.content.fetch("background_run")).to include(
      "run_id" => source_run.id, "state" => "failed", "merge_state" => "merged"
    )
    expect(main_chat.messages.order(:id).last.content.fetch("internal_prompt")).to include("Result: failed", "Background task failed.")
    expect(lifecycle).to have_received(:finalize_background!).with(
      path: StepWorkspace.for(source_step, run: source_run).path,
      workflow: workflow
    )
    expect(job.reload).to have_attributes(state: "closed", closure_reason: "coworker_task")
  end

  it "posts exactly one failure card when failure handling is retried" do
    workflow = Coworkers::Workflow.instantiate(job: job)
    source_step = workflow.steps.find_by!(kind: "coworker_run")
    source_run = Run.create!(job: job, user: owner, step: source_step, trigger_kind: "coworker_run", agent_provider: "codex")
    source_run.update_columns(state: "failed", agent_summary: "The calendar API failed.", finished_at: Time.current)

    2.times { Coworkers::PostToChat.post_failure!(workflow) }

    expect(main_chat.messages.count).to eq(1)
    expect(main_chat.messages.first.content.fetch("background_run")).to include(
      "state" => "failed", "summary" => "The calendar API failed."
    )
    expect(lifecycle).to have_received(:finalize_background!).once
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
