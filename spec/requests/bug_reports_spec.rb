require "rails_helper"

RSpec.describe "Bug reports", type: :request do
  let(:user) { Factories.user }

  describe "layout entry point" do
    it "serves signed-in app pages through the React shell that owns bug reports" do
      repository = Factories.repository(user: user, owner: "tkadauke", name: "syrus")
      job = Factories.job(repository: repository, issue_number: 1)
      sign_in_as(user)

      get job_path(job)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "does not render the bug-report control on auth pages" do
      get new_session_path

      expect(response.body).not_to include("Report a bug")
    end
  end

  it "does not route the retired legacy HTML bug report endpoint" do
    expect {
      Rails.application.routes.recognize_path("/bug_reports", method: :post)
    }.to raise_error(ActionController::RoutingError)
  end
end
