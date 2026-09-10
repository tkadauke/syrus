require "rails_helper"

RSpec.describe Terminal::WorkspaceCandidates, type: :service do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def live_worker_queue!(queue_name, hostname:)
    ensure_solid_queue_test_tables!
    SolidQueue::Process.create!(
      hostname: hostname,
      kind: "worker",
      last_heartbeat_at: Time.current,
      metadata: { "queues" => [ queue_name, "chat" ] },
      name: "#{hostname}:1",
      pid: 123,
      created_at: Time.current
    )
    InstanceVersion.create!(
      hostname: hostname,
      role: "worker",
      version: "test",
      started_at: Time.current,
      last_heartbeat_at: Time.current,
      data_root_path: "/syrus-data/#{hostname}"
    )
  end

  it "ranks actionable workflows ahead of stale succeeded history" do
    stale_job = Factories.job(user: user, repository: repo, issue_title: "Old succeeded work")
    stale_workflow = stale_job.workflows.first
    stale_workflow.update_columns(state: "succeeded", cleaned_up_at: 1.day.ago, created_at: 1.minute.ago, updated_at: 1.minute.ago)

    failed_job = Factories.job(user: user, repository: repo, issue_title: "Fix deploy")
    failed_workflow = failed_job.workflows.first
    failed_workflow.update_columns(state: "failed", created_at: 2.days.ago, updated_at: 2.days.ago)

    labels = described_class.for(user: user).select { |candidate| candidate[:kind] == "workflow" }.map { |candidate| candidate[:label] }
    stale_candidate = described_class.for(user: user).find { |candidate| candidate[:workflow_id] == stale_workflow.id }

    expect(labels.first).to include("Fix deploy")
    expect(labels).to include(a_string_including("Old succeeded work"))
    expect(stale_candidate[:default_visible]).to be(false)
  end

  it "searches workflow, chat, and worker identity fields" do
    job = Factories.job(user: user, repository: repo, issue_title: "Needle migration")
    workflow = job.workflows.first
    workflow.update_columns(worker_hostname: "worker-alpha", worker_storage_key: "storage-alpha")
    live_worker_queue!("resume-storage-alpha", hostname: "worker-alpha")
    chat = ChatSession.create!(user: user, mode: "coding", repository: repo, title: "Needle chat")
    chat_workspace_path = Rails.root.join("tmp", "spec-chat-workspaces", chat.id.to_s)
    FileUtils.mkdir_p(chat_workspace_path)
    chat.update_columns(workspace_path: chat_workspace_path.to_s, coding_checkout_branch: "needle-branch")

    payload = described_class.for(user: user, query: "storage-alpha")
    expect(payload).to include(hash_including(kind: "workflow", workflow_id: workflow.id))
    expect(payload).to include(hash_including(kind: "worker", worker_storage_key: "storage-alpha"))

    chat_payload = described_class.for(user: user, query: "needle-branch")
    expect(chat_payload).to include(hash_including(kind: "chat", chat_session_id: chat.id))
  end

  it "does not emit chat candidates without a recorded workspace path" do
    ChatSession.create!(user: user, mode: "coding", repository: repo, title: "Unmaterialized chat")

    payload = described_class.for(user: user, query: "unmaterialized")

    expect(payload).to be_empty
  end

  it "does not emit chat candidates whose recorded workspace path is not materialized on disk" do
    chat = ChatSession.create!(user: user, mode: "coding", repository: repo, title: "Missing directory")
    chat.update_columns(workspace_path: Rails.root.join("tmp", "missing-chat-workspace-#{chat.id}").to_s)

    payload = described_class.for(user: user, query: "missing directory")

    expect(payload).to be_empty
  end

  it "batch-computes workflow routing without querying runs per workflow" do
    live_worker_queue!("resume-storage-alpha", hostname: "worker-alpha")
    3.times do |index|
      job = Factories.job(user: user, repository: repo, issue_title: "Workflow #{index}")
      job.workflows.first.update_columns(worker_hostname: "worker-alpha", worker_storage_key: "storage-alpha")
    end

    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      queries << sql unless sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|PRAGMA|SELECT sqlite_version)/i)
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      described_class.for(user: user)
    end

    run_queries = queries.grep(/FROM "?runs"?/i)
    expect(run_queries).to be_empty
  end

  it "does not expose another user's workflows or chats" do
    other_repo = Factories.repository(user: other_user, owner: "other", name: "repo")
    Factories.job(user: other_user, repository: other_repo, issue_title: "Private workflow")
    private_chat = ChatSession.create!(user: other_user, mode: "coding", repository: other_repo, title: "Private chat")
    private_chat.update_columns(workspace_path: "/tmp/private-chat")

    payload = described_class.for(user: user, query: "private")

    expect(payload).to be_empty
  end
end
