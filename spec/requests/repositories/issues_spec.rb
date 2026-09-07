require "rails_helper"

RSpec.describe "Repository issues browser", type: :request do
  let(:user) { Factories.user(github_handle: "ada") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus") }

  before { sign_in_as(user) }

  it "serves the SPA shell for the retired repository issue HTML GET path instead of 404ing" do
    get "/repositories/#{repo.id}/issues"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
  end

  it "does not route retired repository issue HTML endpoints" do
    expect {
      Rails.application.routes.recognize_path("/repositories/#{repo.id}/comment_issue", method: :post)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/repositories/#{repo.id}/close_issue", method: :post)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/repositories/#{repo.id}/delegate_issue", method: :post)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/repositories/#{repo.id}/bulk_issues", method: :post)
    }.to raise_error(ActionController::RoutingError)
  end
end
