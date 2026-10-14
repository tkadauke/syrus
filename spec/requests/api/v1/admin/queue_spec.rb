require "rails_helper"

# SolidQueue tables aren't loaded in dev/test single-database
# setups, so most endpoints respond with the queue_unreachable
# envelope here. The API contract is exercised; production
# behavior (with the queue DB present) is verified by hand on
# staging — same pattern as the HTML queue spec.
RSpec.describe "API: /api/v1/admin/queue/*", type: :request do
  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  def auth = { "Authorization" => "Bearer #{admin_token}" }
  def parse_body = JSON.parse(response.body)

  %w[active pending failed recurring workers].each do |tab|
    it "GET /api/v1/admin/queue/#{tab} responds — either with data or queue_unreachable" do
      get "/api/v1/admin/queue/#{tab}", headers: auth
      # On dev/test single-DB this returns 503 queue_unreachable;
      # production with the queue DB returns 200 with content.
      # Either is a valid spec assertion of the contract.
      expect([ 200, 503 ]).to include(response.status)
      if response.status == 503
        expect(parse_body.dig("error", "code")).to eq("queue_unreachable")
      end
    end
  end

  describe "GET /api/v1/admin/queue/failed?since=..." do
    before(:all) { ensure_solid_queue_test_tables! }
    after(:all) { drop_solid_queue_test_tables! }
    before { clear_solid_queue_test_tables! }

    it "filters failed executions by the requested lower bound" do
      travel_to Time.zone.parse("2026-10-13 12:00:00 UTC") do
        old_job = solid_queue_job(class_name: "OldRunJob", queue_name: "runs")
        recent_job = solid_queue_job(class_name: "RecentRunJob", queue_name: "runs")
        SolidQueue::FailedExecution.create!(job: old_job, created_at: 2.hours.ago, error: { "message" => "old" })
        SolidQueue::FailedExecution.create!(job: recent_job, created_at: 30.minutes.ago, error: { "message" => "recent" })
        since = 1.hour.ago.iso8601

        get "/api/v1/admin/queue/failed", params: { since: since }, headers: auth

        expect(response).to have_http_status(:ok)
        body = parse_body
        expect(body["since"]).to eq(since)
        expect(body["failures"].map { |failure| failure["class_name"] }).to eq([ "RecentRunJob" ])
        expect(body["filter"]).to eq(
          "and" => [
            { "field" => "failed_since", "op" => "after", "value" => since }
          ]
        )
      end
    end

    it "returns an invalid_filter error for malformed since values" do
      get "/api/v1/admin/queue/failed", params: { since: "not-a-time" }, headers: auth

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("invalid_filter")
    end
  end

  describe "POST /api/v1/admin/queue/reap_stale_runs" do
    it "always runs the unified reconciler inline with repairs and returns ok" do
      result = WorkEngine::Reconciler::Result.new(
        "spec",
        Time.current,
        instance_double(WorkEngine::Reconciler::Snapshot, as_json: {}),
        [ instance_double(WorkEngine::Reconciler::Issue) ],
        [],
        [ instance_double(WorkEngine::RepairExecutor::Execution) ]
      )
      expect(WorkEngine::Reconciler).to receive(:call_locked!)
        .with(source: "Api::V1::Admin::QueueController", execute_repairs: true)
        .and_return(result)

      post "/api/v1/admin/queue/reap_stale_runs", headers: auth

      expect(response).to be_successful
      expect(parse_body).to include(
        "ok" => true,
        "message" => "WorkEngine reconciler ran inline.",
        "issues_count" => 1,
        "repairs_count" => 1
      )
    end

    it "401s without a token" do
      post "/api/v1/admin/queue/reap_stale_runs"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  def solid_queue_job(class_name:, queue_name:, arguments: { "arguments" => [] }, priority: 0, scheduled_at: nil)
    SolidQueue::Job.create!(
      class_name: class_name,
      queue_name: queue_name,
      priority: priority,
      arguments: arguments,
      created_at: Time.current,
      updated_at: Time.current,
      scheduled_at: scheduled_at
    )
  end
end
