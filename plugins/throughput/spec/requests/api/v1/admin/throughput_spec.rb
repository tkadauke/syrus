require "rails_helper"

RSpec.describe "API: /api/v1/admin/throughput", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:admin_token) { admin.generate_api_token! }
  let(:non_admin) { admin; Factories.user } # second user → not the auto-promoted first admin
  let(:non_admin_token) { non_admin.generate_api_token! }

  def auth(token) = { "Authorization" => "Bearer #{token}" }
  def parse_body = JSON.parse(response.body)

  it "requires an admin token" do
    get "/api/v1/admin/throughput", headers: auth(non_admin_token)

    expect(response).to have_http_status(:forbidden)
  end

  it "answers plugin_disabled when the plugin is disabled" do
    PluginRecord.find_by!(name: "throughput").update!(enabled: false)

    get "/api/v1/admin/throughput", headers: auth(admin_token)

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
  end

  it "buckets instance-wide jobs created, closed, implemented, and pr_merged cycle time" do
    base = Time.utc(2026, 9, 6, 12, 0, 0)
    repository = Factories.repository

    Factories.job_record(repository: repository, state: "queued", created_at: base + 10.minutes)
    Factories.job_record(repository: repository, state: "closed", finished_at: base + 20.minutes)
    Factories.job_record(
      repository: repository,
      state: "closed",
      closure_reason: "pr_merged",
      created_at: base - 50.minutes,
      finished_at: base + 10.minutes
    )
    Factories.job_with_run(
      repository: repository,
      workflow_attrs: { trigger_kind: "initial" },
      step_attrs: { kind: "pr_open", state: "succeeded", finished_at: base + 15.minutes }
    )

    get "/api/v1/admin/throughput", headers: auth(admin_token), params: {
      since: (base - 2.hours).iso8601,
      until: (base + 2.hours).iso8601
    }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["version"]).to eq(Throughput::AdminMetricsPayload::VERSION)
    expect(body["repository"]).to be_nil

    hourly_bucket = body.dig("hourly", "buckets").find { |b| b["bucket_start"] == base.iso8601 }
    expect(hourly_bucket).not_to be_nil
    expect(hourly_bucket["jobs_created"]).to eq(1)
    expect(hourly_bucket["jobs_closed"]).to eq(2) # closed_job + merged_job both finished in this bucket
    expect(hourly_bucket["jobs_implemented"]).to eq(1)
    expect(hourly_bucket.dig("cycle_time_seconds", "sample_count")).to eq(1)
    expect(hourly_bucket.dig("cycle_time_seconds", "median")).to eq(3600) # 50min + 10min

    daily_bucket = body.dig("daily", "buckets").find { |b| b["bucket_start"] == base.beginning_of_day.iso8601 }
    # Both created_job (base+10m) and merged_job (base-50m, still same UTC day) land here.
    expect(daily_bucket["jobs_created"]).to eq(2)
    expect(daily_bucket["jobs_closed"]).to eq(2)
    expect(daily_bucket["jobs_implemented"]).to eq(1)
  end

  it "filters by repository id or owner/name slug" do
    base = Time.utc(2026, 9, 6, 12, 0, 0)
    target = Factories.repository(owner: "acme", name: "target")
    other = Factories.repository(owner: "acme", name: "other")
    Factories.job_record(repository: target, state: "queued", created_at: base + 5.minutes)
    Factories.job_record(repository: other, state: "queued", created_at: base + 5.minutes)

    get "/api/v1/admin/throughput", headers: auth(admin_token), params: {
      repository: "acme/target",
      since: (base - 1.hour).iso8601,
      until: (base + 1.hour).iso8601
    }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["repository"]).to eq("id" => target.id, "slug" => "acme/target")
    bucket = body.dig("hourly", "buckets").find { |b| b["bucket_start"] == base.iso8601 }
    expect(bucket["jobs_created"]).to eq(1)

    get "/api/v1/admin/throughput", headers: auth(admin_token), params: { repository: target.id }

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("repository", "id")).to eq(target.id)
  end

  it "returns not_found for an unknown repository filter" do
    get "/api/v1/admin/throughput", headers: auth(admin_token), params: { repository: "nope/nope" }

    expect(response).to have_http_status(:not_found)
  end
end
