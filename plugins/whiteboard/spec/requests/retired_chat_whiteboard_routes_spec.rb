require "rails_helper"

RSpec.describe "Chat whiteboards", type: :request do
  it "does not route the retired non-API whiteboard endpoint" do
    expect {
      Rails.application.routes.recognize_path("/chats/1/whiteboard", method: :patch)
    }.to raise_error(ActionController::RoutingError)
  end

  it "serves the SPA shell for the retired non-API whiteboard GET path instead of 404ing" do
    user = Factories.user
    sign_in_as(user)

    get "/chats/1/whiteboard"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
  end
end
