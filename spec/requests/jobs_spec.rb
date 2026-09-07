require "rails_helper"

RSpec.describe "Jobs", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  describe "GET /jobs/new" do
    it "serves the React app shell" do
      get new_job_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  describe "GET /jobs/:id" do
    it "serves the React app shell" do
      job = Factories.job_record(repository: repo, issue_number: 42)

      get job_path(job)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  describe "GET /jobs/:id/source" do
    it "serves the React app shell" do
      job = Factories.job_record(repository: repo, issue_number: 42)

      get source_job_path(job)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  it "does not route the retired legacy HTML job commands" do
    [
      [ :post, "/jobs/1/start" ],
      [ :post, "/jobs/1/run_again" ],
      [ :post, "/jobs/1/restart" ],
      [ :post, "/jobs/1/cancel" ],
      [ :post, "/jobs/1/approve" ],
      [ :post, "/jobs/1/unapprove" ],
      [ :post, "/jobs/1/reopen" ],
      [ :post, "/jobs/1/poll_feedback" ],
      [ :post, "/jobs/1/rebase" ],
      [ :post, "/jobs/1/check_mergeability" ],
      [ :post, "/jobs/1/resume" ],
      [ :post, "/jobs/1/stop_run" ],
      [ :post, "/jobs/1/retry_step" ],
      [ :post, "/jobs/1/push_commits" ],
      [ :post, "/jobs/1/diagnose" ],
      [ :post, "/jobs/1/tags" ],
      [ :delete, "/jobs/1/tags/2" ],
      [ :post, "/jobs/1/dependencies" ],
      [ :delete, "/jobs/1/dependencies/2" ],
      [ :post, "/jobs/1/override_dependencies" ],
      [ :patch, "/jobs/1/stack_base" ],
      [ :post, "/jobs/1/mark_valid" ],
      [ :post, "/jobs/1/pin" ],
      [ :delete, "/jobs/1/pin" ],
      [ :post, "/jobs/1/attachments" ],
      [ :delete, "/jobs/1/attachments/2" ]
    ].each do |method, path|
      expect {
        Rails.application.routes.recognize_path(path, method: method)
      }.to raise_error(ActionController::RoutingError), "#{method.upcase} #{path} should not route"
    end
  end

  it "serves the SPA shell for a retired legacy HTML job GET path instead of 404ing" do
    get "/jobs/1/runs/2/grade_log"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
  end
end
