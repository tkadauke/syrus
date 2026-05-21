require "rails_helper"

# Note: SolidQueue's tables aren't loaded in the dev/test
# single-database setup, so the controller's rescue path
# (`@queue_unreachable`) gets exercised here. Production-shape
# behavior (with the queue DB present) is tested by hand via the
# admin UI on staging.
RSpec.describe "Admin queue inspector", type: :request do
  before(:all) { ensure_solid_queue_test_tables! }
  after(:all) { drop_solid_queue_test_tables! }
  before { clear_solid_queue_test_tables! }

  let(:admin) { Factories.user }
  let(:non_admin) do
    admin
    Factories.user
  end

  describe "GET /admin/queue" do
    it "redirects unauthenticated users" do
      get "/admin/queue"
      expect(response).to redirect_to(new_session_path).or redirect_to(new_user_path)
    end

    it "blocks non-admins" do
      sign_in_as(non_admin)
      get "/admin/queue"
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/admin/i)
    end

    it "redirects /admin/queue to /admin/queue/active" do
      sign_in_as(admin)
      get "/admin/queue"
      expect(response).to redirect_to("/admin/queue/active")
    end
  end

  describe "GET /admin/queue/:tab" do
    before { sign_in_as(admin) }

    %w[active pending failed recurring workers].each do |tab|
      it "renders the #{tab} tab successfully (whether SQ tables are reachable or not)" do
        get "/admin/queue/#{tab}"
        expect(response).to be_successful
        expect(response.body).to include("SolidQueue inspector")
      end
    end

    it "ignores an unknown tab — route constraint returns 404" do
      get "/admin/queue/bogus"
      expect(response).to have_http_status(:not_found)
    end

    it "filters active claimed executions by queue_name chip" do
      runs_job = SolidQueue::Job.create!(
        class_name: "RunJob",
        queue_name: "runs",
        priority: 0,
        arguments: { "arguments" => [ 1 ] },
        created_at: Time.current,
        updated_at: Time.current
      )
      chat_job = SolidQueue::Job.create!(
        class_name: "ChatTurnJob",
        queue_name: "chat",
        priority: 0,
        arguments: { "arguments" => [ 2 ] },
        created_at: Time.current,
        updated_at: Time.current
      )
      process = SolidQueue::Process.create!(
        kind: "Worker",
        name: "worker-1",
        hostname: "test-host",
        pid: 123,
        last_heartbeat_at: Time.current,
        created_at: Time.current,
        metadata: {}
      )
      SolidQueue::ClaimedExecution.create!(job: runs_job, process: process, created_at: Time.current)
      SolidQueue::ClaimedExecution.create!(job: chat_job, process: process, created_at: Time.current)

      q = Filters::QueryParam.encode(
        "and" => [
          { "field" => "queue_name", "op" => "is", "value" => "runs" }
        ]
      )

      get "/admin/queue/active", params: { q: q }

      expect(response).to be_successful
      document = Nokogiri::HTML(response.body)
      rows = document.css("table tbody tr").map(&:text).join("\n")
      expect(rows).to include("RunJob")
      expect(rows).to include("runs")
      expect(rows).not_to include("ChatTurnJob")
      expect(rows).not_to include("chat")
    end
  end

  describe "POST /admin/queue/reap_stale_runs" do
    it "blocks non-admins" do
      sign_in_as(non_admin)
      post "/admin/queue/reap_stale_runs"
      expect(response).to redirect_to(root_path)
    end

    it "runs ReapStaleRunsJob inline and redirects" do
      sign_in_as(admin)
      expect(ReapStaleRunsJob).to receive(:perform_now)
      post "/admin/queue/reap_stale_runs"
      expect(response).to redirect_to("/admin/queue/active")
      expect(flash[:notice]).to match(/Reap/)
    end
  end
end
