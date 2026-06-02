require "rails_helper"

RSpec.describe "Dashboard routes", type: :request do
  let(:user) { Factories.user }

  it "serves canonical dashboard pages through the React shell" do
    sign_in_as(user)

    [ dashboard_path, dashboard_epics_path, dashboard_jobs_path, dashboard_workflows_path ].each do |path|
      get path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  it "does not route retired dashboard ERB fallbacks and commands" do
    {
      get: [
        "/dashboard/legacy",
        "/dashboard/epics/legacy",
        "/dashboard/jobs/legacy",
        "/dashboard/workflows/legacy",
        "/epics/1/graph"
      ],
      patch: [
        "/dashboard/preferences",
        "/dashboard/epics/1/auto_approval"
      ],
      post: [
        "/dashboard/epics/bulk",
        "/dashboard/jobs/bulk",
        "/dashboard/landing_pause"
      ]
    }.each do |method, paths|
      paths.each do |path|
        expect {
          Rails.application.routes.recognize_path(path, method: method)
        }.to raise_error(ActionController::RoutingError)
      end
    end
  end
end
