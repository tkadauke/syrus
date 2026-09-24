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

  describe "connection metrics" do
    around do |example|
      original_registry = Syrus::Metrics.registry
      Syrus::Metrics.reset!
      described_class.declare_metrics!
      ApplicationCable::Connection::CONNECTIONS_PER_USER.clear
      example.run
    ensure
      Syrus::Metrics.instance_variable_set(:@registry, original_registry)
      ApplicationCable::Connection::CONNECTIONS_PER_USER.clear
    end

    def cable_connections = Syrus::Metrics.gauge(:syrus_cable_connections).samples.first&.last
    def cable_connections_per_user_max = Syrus::Metrics.gauge(:syrus_cable_connections_per_user_max).samples.first&.last

    it "tracks live connections and the busiest single user across connect/disconnect" do
      alice = Factories.user(api_token: "syrus_alice_token")
      bob = Factories.user(api_token: "syrus_bob_token")

      connect "/cable?api_token=#{alice.api_token}"
      first_alice_connection = connection
      expect(cable_connections).to eq(1)
      expect(cable_connections_per_user_max).to eq(1)

      connect "/cable?api_token=#{alice.api_token}"
      expect(cable_connections).to eq(2)
      expect(cable_connections_per_user_max).to eq(2)

      connect "/cable?api_token=#{bob.api_token}"
      expect(cable_connections).to eq(3)
      expect(cable_connections_per_user_max).to eq(2)

      first_alice_connection.disconnect
      expect(cable_connections).to eq(2)
      expect(cable_connections_per_user_max).to eq(1)
    end
  end
end
