require "rails_helper"

RSpec.describe "Repository whiteboards", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  it "does not route the retired repository-wide whiteboard endpoint" do
    expect {
      Rails.application.routes.recognize_path("/repositories/#{repo.id}/whiteboard", method: :get)
    }.to raise_error(ActionController::RoutingError)

    get "/repositories/#{repo.id}/whiteboard", as: :json

    expect(response).to have_http_status(:not_found)
  end
end
