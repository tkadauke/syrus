require "rails_helper"

RSpec.describe "API: repository GitHub issue routes", type: :request do
  it "does not route the removed issue comment endpoint" do
    expect {
      Rails.application.routes.recognize_path("/api/v1/app/repositories/1/issues/comment", method: :post)
    }.to raise_error(ActionController::RoutingError)
  end
end
