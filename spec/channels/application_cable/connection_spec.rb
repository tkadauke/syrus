require "rails_helper"

RSpec.describe ApplicationCable::Connection, type: :channel do
  it "connects with an API token query parameter" do
    user = Factories.user(api_token: "syrus_desktop_token")

    connect "/cable?api_token=syrus_desktop_token"

    expect(connection.current_user).to eq(user)
  end

  it "rejects an invalid API token query parameter" do
    expect {
      connect "/cable?api_token=invalid"
    }.to have_rejected_connection
  end
end
