require "rails_helper"

RSpec.describe "Chat whiteboards", type: :request do
  it "does not route the retired non-API whiteboard endpoint" do
    expect {
      Rails.application.routes.recognize_path("/chats/1/whiteboard", method: :get)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/chats/1/whiteboard", method: :patch)
    }.to raise_error(ActionController::RoutingError)
  end
end
