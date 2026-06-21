require "rails_helper"

RSpec.describe SyrusChatMcp::ReadQueueTool do
  before(:all) { ensure_solid_queue_test_tables! }
  after(:all) { drop_solid_queue_test_tables! }
  before { clear_solid_queue_test_tables! }

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "read_queue", arguments: {} } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "returns a compact Solid Queue health snapshot" do
    solid_queue_process(hostname: "worker-a", pid: 101, metadata: { "queues" => "runs,chat", "thread_pool_size" => 2 })
    run_job = solid_queue_job(class_name: "RunJob", queue_name: "runs")
    chat_job = solid_queue_job(class_name: "ChatTurnJob", queue_name: "chat")
    failed_job = solid_queue_job(class_name: "RunJob", queue_name: "runs")
    blocked_job = solid_queue_job(class_name: "RunJob", queue_name: "merges")
    run_job.ready_execution.update!(created_at: 2.minutes.ago)
    chat_job.ready_execution.update!(created_at: 1.minute.ago)
    failed_job.ready_execution.destroy!
    blocked_job.ready_execution.destroy!
    SolidQueue::FailedExecution.create!(job: failed_job, created_at: 1.minute.ago, error: { "message" => "boom" })
    SolidQueue::RecurringTask.create!(key: "poll", class_name: "PollAllRepositoriesJob", schedule: "*/5 * * * *", static: true, created_at: Time.current, updated_at: Time.current)
    SolidQueue::BlockedExecution.insert_all!(
      [
        {
          job_id: blocked_job.id,
          queue_name: "merges",
          concurrency_key: "job-1",
          priority: 0,
          expires_at: 5.minutes.from_now,
          created_at: Time.current
        }
      ]
    )
    SolidQueue::Pause.create!(queue_name: "default", created_at: Time.current)

    response = call_tool
    payload = response_payload(response)

    expect(response[:result][:isError]).to be_falsey
    expect(payload.fetch(:active_workers)).to include(count: 1, queues: %w[chat runs])
    expect(payload.dig(:active_workers, :workers).first).to include(hostname: "worker-a", pid: 101, queues: %w[runs chat], threads: 2, stale: false)
    expect(payload.fetch(:pending_jobs)).to include(runs: 1, chat: 1, default: 0, merges: 0)
    expect(payload.fetch(:failed_jobs)).to eq(count: 1)
    expect(payload.fetch(:recurring_tasks)).to eq(count: 1)
    expect(payload.fetch(:blocked_queues)).to eq([ "merges" ])
    expect(payload.fetch(:paused_queues)).to eq([ "default" ])
  end

  def solid_queue_job(class_name:, queue_name:)
    SolidQueue::Job.create!(
      class_name: class_name,
      queue_name: queue_name,
      priority: 0,
      arguments: { "arguments" => [] },
      created_at: Time.current,
      updated_at: Time.current
    )
  end

  def solid_queue_process(kind: "Worker", hostname:, pid:, metadata: {})
    SolidQueue::Process.create!(
      kind: kind,
      name: "#{kind.downcase}-#{pid}",
      hostname: hostname,
      pid: pid,
      last_heartbeat_at: Time.current,
      created_at: Time.current,
      metadata: metadata
    )
  end
end
