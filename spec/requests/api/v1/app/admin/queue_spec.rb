require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/queue/*", type: :request do
  before(:all) { ensure_solid_queue_test_tables! }
  after(:all) { drop_solid_queue_test_tables! }
  before { clear_solid_queue_test_tables! }

  def parse_body
    JSON.parse(response.body)
  end

  let(:admin) { Factories.user }
  let(:non_admin) do
    admin
    Factories.user
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/queue/active"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/queue/active"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns active claimed executions for admin users" do
    sign_in_as(admin)
    process = solid_queue_process(hostname: "worker-a", pid: 101)
    run_job = solid_queue_job(class_name: "RunJob", queue_name: "runs", arguments: { "arguments" => [ 42 ] })
    chat_job = solid_queue_job(class_name: "ChatTurnJob", queue_name: "chat", arguments: { "arguments" => [ 7 ] })
    SolidQueue::ClaimedExecution.create!(job: run_job, process: process, created_at: 2.minutes.ago)
    SolidQueue::ClaimedExecution.create!(job: chat_job, process: process, created_at: 1.minute.ago)

    get "/api/v1/app/admin/queue/active"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["jobs"].map { |job| job["class_name"] }).to eq([ "ChatTurnJob", "RunJob" ])
    expect(body["jobs"].first).to include(
      "queue_name" => "chat",
      "arguments" => [ 7 ]
    )
    expect(body["filter"]).to eq("and" => [])
    expect(body.dig("controls", "filter_schema").map { |field| field["field"] }).to include("queue_name", "job_class")
    expect(body["smart_folders"].find { |folder| folder["name"] == "Runs" }).to include(
      "count" => 1,
      "i18n_key" => "admin_queue_runs",
      "position" => SmartFolder.for_subject(:admin_queue).find_by!(name: "Runs").position,
      "path" => a_string_matching(%r{\A/admin/queue/active\?smart_folder_id=})
    )
  end

  it "applies queue smart folders to filter jobs" do
    sign_in_as(admin)
    SmartFolder.ensure_admin_queue_builtins!
    process = solid_queue_process(hostname: "worker-a", pid: 101)
    run_job = solid_queue_job(class_name: "RunJob", queue_name: "runs")
    chat_job = solid_queue_job(class_name: "ChatTurnJob", queue_name: "chat")
    SolidQueue::ClaimedExecution.create!(job: run_job, process: process, created_at: 2.minutes.ago)
    SolidQueue::ClaimedExecution.create!(job: chat_job, process: process, created_at: 1.minute.ago)
    folder = SmartFolder.for_subject(:admin_queue).find_by!(name: "Runs")

    get "/api/v1/app/admin/queue/active", params: { smart_folder_id: folder.id }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["active_smart_folder_id"]).to eq(folder.id)
    expect(body["jobs"].map { |job| job["queue_name"] }).to eq([ "runs" ])
    expect(body["filter"]).to eq(
      "and" => [
        { "field" => "queue_name", "op" => "is", "value" => "runs" }
      ]
    )
    expect(body["smart_folders"].find { |row| row["id"] == folder.id }).to include("active" => true, "count" => 1)
  end

  it "returns the active user-defined queue folder filter when no q is present" do
    sign_in_as(admin)
    process = solid_queue_process(hostname: "worker-a", pid: 101)
    run_job = solid_queue_job(class_name: "RunJob", queue_name: "runs")
    chat_job = solid_queue_job(class_name: "ChatTurnJob", queue_name: "chat")
    SolidQueue::ClaimedExecution.create!(job: run_job, process: process, created_at: 2.minutes.ago)
    SolidQueue::ClaimedExecution.create!(job: chat_job, process: process, created_at: 1.minute.ago)
    folder_tree = {
      "and" => [
        { "field" => "queue_name", "op" => "is", "value" => "runs" }
      ]
    }
    folder = admin.smart_folders.create!(
      name: "Run queue",
      kind: "user_defined",
      subject_type: "admin_queue",
      filter: folder_tree,
      position: 0
    )

    get "/api/v1/app/admin/queue/active", params: { smart_folder_id: folder.id }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["filter"]).to eq(folder_tree)
    expect(body["jobs"].map { |job| job["queue_name"] }).to eq([ "runs" ])
  end

  it "returns only the URL queue filter when a user-defined folder also has q" do
    sign_in_as(admin)
    process = solid_queue_process(hostname: "worker-a", pid: 101)
    run_job = solid_queue_job(class_name: "RunJob", queue_name: "runs")
    chat_job = solid_queue_job(class_name: "ChatTurnJob", queue_name: "chat")
    SolidQueue::ClaimedExecution.create!(job: run_job, process: process, created_at: 2.minutes.ago)
    SolidQueue::ClaimedExecution.create!(job: chat_job, process: process, created_at: 1.minute.ago)
    folder_tree = {
      "and" => [
        { "field" => "queue_name", "op" => "is", "value" => "runs" }
      ]
    }
    url_tree = {
      "and" => [
        { "field" => "queue_name", "op" => "is", "value" => "chat" }
      ]
    }
    folder = admin.smart_folders.create!(
      name: "Run queue",
      kind: "user_defined",
      subject_type: "admin_queue",
      filter: folder_tree,
      position: 0
    )

    get "/api/v1/app/admin/queue/active", params: { smart_folder_id: folder.id, q: Filters::QueryParam.encode(url_tree) }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["filter"]).to eq(url_tree)
    expect(body["jobs"].map { |job| job["queue_name"] }).to eq([ "chat" ])
  end

  it "returns pending ready executions with a total" do
    sign_in_as(admin)
    run_job = solid_queue_job(class_name: "RunJob", queue_name: "runs")
    chat_job = solid_queue_job(class_name: "ChatTurnJob", queue_name: "chat")
    chat_job.ready_execution.update!(created_at: 2.minutes.ago)
    run_job.ready_execution.update!(created_at: 1.minute.ago)

    get "/api/v1/app/admin/queue/pending"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["total"]).to eq(2)
    expect(body["jobs"].map { |job| job["queue_name"] }).to eq([ "chat", "runs" ])
  end

  it "includes i18n_key for builtin folders and nil for user-defined folders" do
    sign_in_as(admin)
    admin.smart_folders.create!(
      name: "My queue",
      kind: "user_defined",
      subject_type: "admin_queue",
      filter: { "and" => [] },
      position: 0
    )

    get "/api/v1/app/admin/queue/active"

    expect(response).to have_http_status(:ok)
    body = parse_body
    builtin = body["smart_folders"].find { |folder| folder["name"] == "Failed today" }
    expect(builtin).to include("i18n_key" => "failed_today", "kind" => "builtin")
    user_defined = body["smart_folders"].find { |folder| folder["name"] == "My queue" }
    expect(user_defined).to include("i18n_key" => nil, "kind" => "user_defined")
  end

  it "handles queue filters with unknown fields" do
    sign_in_as(admin)
    tree = { "and" => [ { "field" => "retired_field", "op" => "is", "value" => "runs" } ] }

    get "/api/v1/app/admin/queue/active", params: { q: Filters::QueryParam.encode(tree) }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("invalid_filter")
  end

  it "returns recent failed executions" do
    sign_in_as(admin)
    failed_job = solid_queue_job(class_name: "RunJob", queue_name: "runs", arguments: { "arguments" => [ 9 ] })
    SolidQueue::FailedExecution.create!(
      job: failed_job,
      created_at: 5.minutes.ago,
      error: { "exception_class" => "RuntimeError", "message" => "boom" }
    )

    get "/api/v1/app/admin/queue/failed"

    expect(response).to have_http_status(:ok)
    expect(parse_body["failures"].first).to include(
      "class_name" => "RunJob",
      "arguments" => [ 9 ],
      "exception_class" => "RuntimeError",
      "message" => "boom"
    )
    expect(parse_body["filter"]).to eq(
      "and" => [
        { "field" => "failed_since", "op" => "within_last", "value" => { "n" => 1, "unit" => "days" } }
      ]
    )
  end

  it "handles malformed failed_since filter durations" do
    sign_in_as(admin)
    tree = { "and" => [ { "field" => "failed_since", "op" => "within_last", "value" => { "n" => 1, "unit" => "" } } ] }

    get "/api/v1/app/admin/queue/failed", params: { q: Filters::QueryParam.encode(tree) }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("invalid_filter")
  end

  it "returns recurring task status" do
    sign_in_as(admin)
    recurring_job = solid_queue_job(class_name: "PollAllRepositoriesJob", queue_name: "default", finished_at: Time.current)
    SolidQueue::RecurringTask.create!(
      key: "poll_repositories",
      class_name: "PollAllRepositoriesJob",
      schedule: "*/5 * * * *",
      static: true,
      created_at: 1.day.ago,
      updated_at: 1.day.ago
    )
    SolidQueue::RecurringExecution.create!(
      task_key: "poll_repositories",
      job: recurring_job,
      run_at: 10.minutes.ago,
      created_at: 10.minutes.ago
    )

    get "/api/v1/app/admin/queue/recurring"

    expect(response).to have_http_status(:ok)
    expect(parse_body["tasks"].first).to include(
      "key" => "poll_repositories",
      "class_name" => "PollAllRepositoriesJob",
      "schedule" => "*/5 * * * *"
    )
    expect(parse_body["tasks"].first["last_run_at"]).to be_present
    expect(parse_body["tasks"].first["last_finished_at"]).to be_present
  end

  it "returns worker and process inventory" do
    sign_in_as(admin)
    solid_queue_process(hostname: "worker-a", pid: 101, metadata: { "queues" => "runs", "thread_pool_size" => 2 })
    solid_queue_process(kind: "Dispatcher", hostname: "dispatcher-a", pid: 202)
    InstanceVersion.create!(hostname: "worker-a", role: "worker", version: "abc123",
                            started_at: 5.minutes.ago, last_heartbeat_at: 10.seconds.ago)
    WorkerHostHealthSample.create!(hostname: "worker-a", role: "worker", version: "abc123",
                                   observed_at: 1.minute.ago,
                                   cpu_used_percent: 20,
                                   memory_used_percent: 40,
                                   data_root_used_percent: 50)

    get "/api/v1/app/admin/queue/workers"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["workers"].first).to include(
      "hostname" => "worker-a",
      "pid" => 101,
      "queues" => [ "runs" ],
      "threads" => 2,
      "stale" => false
    )
    expect(body["all_processes"].map { |process| process["kind"] }).to eq([ "Dispatcher", "Worker" ])
    expect(body.dig("worker_health", "current", 0)).to include(
      "hostname" => "worker-a",
      "health" => include("level" => "ok")
    )
  end

  it "runs ReapStaleRunsJob inline" do
    sign_in_as(admin)
    expect(ReapStaleRunsJob).to receive(:perform_now)

    post "/api/v1/app/admin/queue/reap_stale_runs"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "ok" => true,
      "message" => "ReapStaleRunsJob ran inline."
    )
  end

  def solid_queue_job(class_name:, queue_name:, arguments: { "arguments" => [] }, finished_at: nil)
    SolidQueue::Job.create!(
      class_name: class_name,
      queue_name: queue_name,
      priority: 0,
      arguments: arguments,
      created_at: Time.current,
      updated_at: Time.current,
      finished_at: finished_at
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
