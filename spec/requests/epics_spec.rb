require "rails_helper"
require "cgi"

RSpec.describe "Epics", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  describe "GET /epics" do
    it "redirects to the canonical Epic dashboard route" do
      get epics_path

      expect(response).to have_http_status(:found)
      expect(response).to redirect_to("/dashboard/epics")
    end

    it "preserves query params in the compatibility redirect" do
      q = Filters::QueryParam.encode("and" => [ { "field" => "state", "op" => "is", "value" => "ready" } ])

      get epics_path, params: { q: q, smart_folder_id: "12", subject: "job" }

      expect(response).to have_http_status(:found)
      expect(response.location).to eq("http://www.example.com/dashboard/epics?q=#{CGI.escape(q)}&smart_folder_id=12")
    end
  end

  describe "GET /epics/new" do
    it "requires authentication" do
      user

      get new_epic_path

      expect(response).to redirect_to(new_session_path)
    end

    it "serves the React app shell" do
      sign_in_as(user)

      get new_epic_path

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  describe "GET /epics/:id" do
    it "requires authentication" do
      epic = Factories.epic(user: user, repository: repo)

      get epic_path(epic)

      expect(response).to redirect_to(new_session_path)
    end

    it "serves the React app shell" do
      sign_in_as(user)
      epic = Factories.epic(user: user, repository: repo, title: "Restore forum")

      get epic_path(epic)

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  describe "GET /epics/:id/edit" do
    it "serves the React app shell" do
      sign_in_as(user)
      epic = Factories.epic(user: user, repository: repo)

      get edit_epic_path(epic)

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  it "does not route retired Epic HTML page, form, and command endpoints" do
    [
      [ :post, "/epics" ],
      [ :patch, "/epics/1" ],
      [ :patch, "/epics/1/archive" ],
      [ :patch, "/epics/1/state" ]
    ].each do |method, path|
      expect {
        Rails.application.routes.recognize_path(path, method: method)
      }.to raise_error(ActionController::RoutingError), "#{method.upcase} #{path} should not route"
    end
  end

  it "serves the SPA shell for retired Epic HTML GET paths instead of 404ing" do
    sign_in_as(user)

    [ "/epics/new/legacy", "/epics/1/legacy", "/epics/1/edit/legacy", "/epics/1/graph" ].each do |path|
      get path

      expect(response).to have_http_status(:ok), "expected #{path} to serve the SPA shell"
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end
end
