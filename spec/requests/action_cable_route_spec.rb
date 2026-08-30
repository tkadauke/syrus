require "rails_helper"

RSpec.describe "Action Cable route", type: :request do
  it "mounts the websocket endpoint used by the Syrus local CLI" do
    paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }

    expect(paths).to include("/cable")
  end
end
