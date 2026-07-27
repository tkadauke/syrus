require "rails_helper"

RSpec.describe "SyrusChatMcp scheduled task tools" do
  let!(:_bootstrap_admin) { Factories.user(admin: true) }

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        SyrusChatMcp::ListScheduledTasksTool,
        SyrusChatMcp::ReadScheduledTaskTool,
        SyrusChatMcp::UpdateScheduledTaskTool,
        SyrusChatMcp::PauseScheduledTaskTool,
        SyrusChatMcp::ResumeScheduledTaskTool,
        SyrusChatMcp::DeleteScheduledTaskTool
      ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(name, arguments = {})
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: name, arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  def create_scheduled_task(attrs = {})
    task_repository = attrs.delete(:repository) || repository
    task_repository.scheduled_tasks.create!({
      user: user,
      kind: "cron",
      name: "Daily review",
      prompt: "Review the repository.",
      cron_expression: "0 9 * * *",
      pr_pileup_policy: "skip"
    }.merge(attrs))
  end

  it "lists non-archived scheduled tasks across the user's repositories" do
    first_task = create_scheduled_task(
      name: "First",
      cron_expression: "0 9 * * *",
      last_fired_at: Time.utc(2026, 6, 20, 9)
    )
    paused_task = create_scheduled_task(
      name: "Paused",
      cron_expression: "0 10 * * *",
      state: "paused"
    )
    create_scheduled_task(name: "Archived", archived_at: Time.current)
    other_repository = Factories.repository(user: user)
    other_task = create_scheduled_task(
      repository: other_repository,
      name: "Other repo",
      cron_expression: "0 11 * * *"
    )
    outsider_repository = Factories.repository
    outsider_repository.scheduled_tasks.create!(
      user: outsider_repository.user,
      kind: "cron",
      name: "Outsider",
      prompt: "Ignore this.",
      cron_expression: "0 12 * * *",
      pr_pileup_policy: "skip"
    )

    response = call_tool("list_scheduled_tasks")
    tasks = payload(response).fetch(:tasks)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(tasks.map { |task| task.fetch(:id) }).to eq([ first_task.id, paused_task.id, other_task.id ])
    expect(tasks.first).to include(
      repository_slug: repository.slug,
      label: "First",
      cron_expression: "0 9 * * *",
      enabled: true,
      last_fired_at: "2026-06-20T09:00:00Z",
      created_at: first_task.created_at.iso8601
    )
    expect(tasks.second).to include(label: "Paused", enabled: false)
    expect(tasks.third).to include(repository_slug: other_repository.slug, label: "Other repo")
  end

  it "works without a repository pinned to the chat session" do
    chat_session.update!(repository: nil)
    task = create_scheduled_task(name: "First")

    response = call_tool("list_scheduled_tasks")
    tasks = payload(response).fetch(:tasks)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(tasks.map { |result| result.fetch(:id) }).to eq([ task.id ])
  end

  it "does not list scheduled tasks owned by another user" do
    task = create_scheduled_task(name: "First")
    other_repository = Factories.repository
    other_repository.scheduled_tasks.create!(
      user: other_repository.user,
      kind: "cron",
      name: "Other repo",
      prompt: "Ignore this.",
      cron_expression: "0 11 * * *",
      pr_pileup_policy: "skip"
    )

    response = call_tool("list_scheduled_tasks")
    tasks = payload(response).fetch(:tasks)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(tasks.map { |result| result.fetch(:id) }).to eq([ task.id ])
  end

  it "pauses an enabled scheduled task" do
    task = create_scheduled_task

    response = call_tool("pause_scheduled_task", scheduled_task_id: task.id)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload(response)).to eq(scheduled_task_id: task.id, label: "Daily review", enabled: false)
    expect(task.reload.state).to eq("paused")
  end

  it "rejects pausing a disabled scheduled task" do
    task = create_scheduled_task(state: "paused")

    response = call_tool("pause_scheduled_task", scheduled_task_id: task.id)

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("already disabled")
  end

  it "resumes a disabled scheduled task" do
    task = create_scheduled_task(state: "paused", consecutive_failure_count: 2)

    response = call_tool("resume_scheduled_task", scheduled_task_id: task.id)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload(response)).to eq(scheduled_task_id: task.id, label: "Daily review", enabled: true)
    expect(task.reload).to have_attributes(state: "scheduled", consecutive_failure_count: 0)
  end

  it "rejects resuming an enabled scheduled task" do
    task = create_scheduled_task

    response = call_tool("resume_scheduled_task", scheduled_task_id: task.id)

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("already enabled")
  end

  it "archives a scheduled task through delete" do
    task = create_scheduled_task(name: "Cleanup")

    response = call_tool("delete_scheduled_task", scheduled_task_id: task.id)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload(response)).to eq(scheduled_task_id: task.id, label: "Cleanup", deleted: true)
    expect(task.reload.archived_at).to be_present
  end

  it "archives a scheduled task in another repository owned by the user" do
    other_task = create_scheduled_task(repository: Factories.repository(user: user), name: "Other repo")

    response = call_tool("delete_scheduled_task", scheduled_task_id: other_task.id)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload(response)).to eq(scheduled_task_id: other_task.id, label: "Other repo", deleted: true)
    expect(other_task.reload.archived_at).to be_present
  end

  it "rejects scheduled tasks owned by another user" do
    other_repository = Factories.repository
    other_task = other_repository.scheduled_tasks.create!(
      user: other_repository.user,
      kind: "cron",
      name: "Other repo",
      prompt: "Ignore this.",
      cron_expression: "0 11 * * *",
      pr_pileup_policy: "skip"
    )

    response = call_tool("delete_scheduled_task", scheduled_task_id: other_task.id)

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("scheduled task not found")
    expect(other_task.reload.archived_at).to be_nil
  end

  it "reads full details of a scheduled task including prompt" do
    task = create_scheduled_task(
      name: "Nightly audit",
      cron_expression: "0 2 * * *",
      last_fired_at: Time.utc(2026, 7, 26, 2),
      consecutive_failure_count: 1
    )

    response = call_tool("read_scheduled_task", scheduled_task_id: task.id)

    expect(response.dig(:result, :isError)).to be_falsey
    result = payload(response).fetch(:scheduled_task)
    expect(result).to include(
      id: task.id,
      label: "Nightly audit",
      kind: "cron",
      state: "scheduled",
      cron_expression: "0 2 * * *",
      prompt: "Review the repository.",
      pr_pileup_policy: "skip",
      enabled: true,
      last_fired_at: "2026-07-26T02:00:00Z",
      consecutive_failure_count: 1,
      created_at: task.created_at.iso8601
    )
  end

  it "reads a scheduled task in another repository owned by the user" do
    other_task = create_scheduled_task(repository: Factories.repository(user: user), name: "Other repo")

    response = call_tool("read_scheduled_task", scheduled_task_id: other_task.id)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload(response).dig(:scheduled_task, :id)).to eq(other_task.id)
  end

  it "rejects reading a scheduled task owned by another user" do
    other_repository = Factories.repository
    other_task = other_repository.scheduled_tasks.create!(
      user: other_repository.user,
      kind: "cron",
      name: "Other task",
      prompt: "Ignore this.",
      cron_expression: "0 3 * * *",
      pr_pileup_policy: "skip"
    )

    response = call_tool("read_scheduled_task", scheduled_task_id: other_task.id)

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("scheduled task not found")
  end

  it "allows admin to read any scheduled task" do
    admin_session = ChatSession.create!(user: Factories.user(admin: true))
    other_task = create_scheduled_task(name: "Owned by other user")

    admin_server = MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ SyrusChatMcp::ReadScheduledTaskTool ],
      server_context: { chat_session: admin_session }
    )
    raw = admin_server.handle_json({
      jsonrpc: "2.0", id: 1, method: "tools/call",
      params: { name: "read_scheduled_task", arguments: { scheduled_task_id: other_task.id } }
    }.to_json)
    response = JSON.parse(raw, symbolize_names: true)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload(response).dig(:scheduled_task, :id)).to eq(other_task.id)
  end

  it "does not include prompt in list_scheduled_tasks response" do
    create_scheduled_task(name: "With prompt", prompt: "Secret prompt text")

    response = call_tool("list_scheduled_tasks")
    tasks = payload(response).fetch(:tasks)

    expect(tasks.first).not_to have_key(:prompt)
  end

  it "includes new metadata fields in list_scheduled_tasks response" do
    task = create_scheduled_task(
      name: "Full metadata",
      cron_expression: "0 8 * * *",
      consecutive_failure_count: 3
    )

    response = call_tool("list_scheduled_tasks")
    tasks = payload(response).fetch(:tasks)

    expect(tasks.first).to include(
      kind: "cron",
      state: "scheduled",
      pr_pileup_policy: "skip",
      consecutive_failure_count: 3
    )
  end

  it "updates name and prompt on a scheduled task" do
    task = create_scheduled_task(name: "Old name", prompt: "Old prompt")

    response = call_tool("update_scheduled_task",
      scheduled_task_id: task.id,
      name: "New name",
      prompt: "New prompt"
    )

    expect(response.dig(:result, :isError)).to be_falsey
    result = payload(response).fetch(:scheduled_task)
    expect(result).to include(label: "New name", prompt: "New prompt")
    expect(task.reload).to have_attributes(name: "New name", prompt: "New prompt")
  end

  it "updates cron_expression on a cron task" do
    task = create_scheduled_task(cron_expression: "0 9 * * *")

    response = call_tool("update_scheduled_task",
      scheduled_task_id: task.id,
      cron_expression: "0 18 * * *"
    )

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload(response).dig(:scheduled_task, :cron_expression)).to eq("0 18 * * *")
    expect(task.reload.cron_expression).to eq("0 18 * * *")
  end

  it "updates pr_pileup_policy on a scheduled task" do
    task = create_scheduled_task(pr_pileup_policy: "skip")

    response = call_tool("update_scheduled_task",
      scheduled_task_id: task.id,
      pr_pileup_policy: "pile"
    )

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload(response).dig(:scheduled_task, :pr_pileup_policy)).to eq("pile")
    expect(task.reload.pr_pileup_policy).to eq("pile")
  end

  it "rejects cron_expression on a one_shot task" do
    task = create_scheduled_task(
      kind: "one_shot",
      fire_at: 1.day.from_now,
      cron_expression: nil
    )

    response = call_tool("update_scheduled_task",
      scheduled_task_id: task.id,
      cron_expression: "0 9 * * *"
    )

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("one_shot")
  end

  it "rejects fire_at on a cron task" do
    task = create_scheduled_task(kind: "cron", cron_expression: "0 9 * * *")

    response = call_tool("update_scheduled_task",
      scheduled_task_id: task.id,
      fire_at: 1.day.from_now.iso8601
    )

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("cron task")
  end

  it "surfaces validation errors for an invalid cron expression" do
    task = create_scheduled_task(cron_expression: "0 9 * * *")

    response = call_tool("update_scheduled_task",
      scheduled_task_id: task.id,
      cron_expression: "not-a-cron"
    )

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to match(/cron/i)
    expect(task.reload.cron_expression).to eq("0 9 * * *")
  end

  it "returns an error when no fields are provided" do
    task = create_scheduled_task

    response = call_tool("update_scheduled_task", scheduled_task_id: task.id)

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("no fields provided")
  end

  it "rejects updating a scheduled task owned by another user" do
    other_repository = Factories.repository
    other_task = other_repository.scheduled_tasks.create!(
      user: other_repository.user,
      kind: "cron",
      name: "Other task",
      prompt: "Ignore this.",
      cron_expression: "0 3 * * *",
      pr_pileup_policy: "skip"
    )

    response = call_tool("update_scheduled_task",
      scheduled_task_id: other_task.id,
      name: "Hijacked name"
    )

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("scheduled task not found")
    expect(other_task.reload.name).to eq("Other task")
  end

  it "allows admin to update any scheduled task" do
    admin_session = ChatSession.create!(user: Factories.user(admin: true))
    task = create_scheduled_task(name: "Owned by regular user")

    admin_server = MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ SyrusChatMcp::UpdateScheduledTaskTool ],
      server_context: { chat_session: admin_session }
    )
    raw = admin_server.handle_json({
      jsonrpc: "2.0", id: 1, method: "tools/call",
      params: { name: "update_scheduled_task", arguments: { scheduled_task_id: task.id, name: "Admin updated" } }
    }.to_json)
    response = JSON.parse(raw, symbolize_names: true)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(task.reload.name).to eq("Admin updated")
  end
end
