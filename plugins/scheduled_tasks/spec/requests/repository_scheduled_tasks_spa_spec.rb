require "rails_helper"

RSpec.describe "Repository scheduled tasks", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  it "serves the React repository scheduled tasks shell" do
    get repository_scheduled_tasks_path(repo)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
  end

  it "does not route the retired repository scheduled-task HTML endpoints" do
    expect {
      Rails.application.routes.recognize_path("/repositories/#{repo.id}/scheduled_tasks", method: :post)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/repositories/#{repo.id}/scheduled_tasks/1", method: :patch)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/repositories/#{repo.id}/scheduled_tasks/1", method: :delete)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/repositories/#{repo.id}/scheduled_tasks/legacy/1", method: :patch)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/repositories/#{repo.id}/scheduled_tasks/legacy/1", method: :delete)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/repositories/#{repo.id}/scheduled_tasks/legacy", method: :post)
    }.to raise_error(ActionController::RoutingError)
  end

  it "serves the SPA shell for retired repository scheduled-task GET paths instead of 404ing" do
    [
      "/repositories/#{repo.id}/scheduled_tasks/legacy",
      "/repositories/#{repo.id}/scheduled_tasks/legacy/new"
    ].each do |path|
      get path

      expect(response).to have_http_status(:ok), "expected #{path} to serve the SPA shell"
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end
end
