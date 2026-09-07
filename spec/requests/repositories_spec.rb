require "rails_helper"

RSpec.describe "Repositories", type: :request do
  let(:user) { Factories.user }

  it "requires authentication on index" do
    user

    get repositories_path

    expect(response).to redirect_to(new_session_path)
  end

  it "requires authentication on show" do
    repo = Factories.repository(user: user)

    get repository_path(repo)

    expect(response).to redirect_to(new_session_path)
  end

  context "signed in" do
    before { sign_in_as(user) }

    it "serves the React app shell for repository routes" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")

      get repositories_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')

      get new_repository_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')

      get edit_repository_path(repo)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')

      get repository_path(repo)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "does not route retired repository list and form endpoints" do
      [
        [ :post, "/repositories" ],
        [ :patch, "/repositories/1" ],
        [ :delete, "/repositories/1" ]
      ].each do |method, path|
        expect {
          Rails.application.routes.recognize_path(path, method: method)
        }.to raise_error(ActionController::RoutingError), "#{method.upcase} #{path} should not route"
      end
    end

    it "does not route retired repository command endpoints" do
      [
        [ :post, "/repositories/1/poll" ],
        [ :post, "/repositories/1/archive" ],
        [ :post, "/repositories/1/unarchive" ],
        [ :post, "/repositories/1/retry_failed_jobs" ]
      ].each do |method, path|
        expect {
          Rails.application.routes.recognize_path(path, method: method)
        }.to raise_error(ActionController::RoutingError), "#{method.upcase} #{path} should not route"
      end
    end

    it "does not route retired repository-scoped HTML endpoints" do
      [
        [ :post, "/repositories/1/notes" ],
        [ :delete, "/repositories/1/notes/2" ]
      ].each do |method, path|
        expect {
          Rails.application.routes.recognize_path(path, method: method)
        }.to raise_error(ActionController::RoutingError), "#{method.upcase} #{path} should not route"
      end
    end

    it "serves the SPA shell for retired repository GET paths instead of 404ing" do
      [
        "/repositories/legacy",
        "/repositories/new/legacy",
        "/repositories/1/edit/legacy",
        "/repositories/owners",
        "/repositories/repos",
        "/repositories/branches",
        "/repositories/1/legacy",
        "/repositories/1/proposals"
      ].each do |path|
        get path

        expect(response).to have_http_status(:ok), "expected #{path} to serve the SPA shell"
        expect(response.body).to include('id="syrus-spa-root"')
      end
    end
  end
end
