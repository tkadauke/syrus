require "rails_helper"

RSpec.describe AlertmanagerInvestigations::Client do
  let(:configuration) do
    instance_double(
      AlertmanagerInvestigations::Configuration,
      base_url: "https://alerts.example.test",
      bearer_token: nil
    )
  end

  it "returns active, unsilenced, uninhibited alerts from Alertmanager" do
    stub_request(:get, "https://alerts.example.test/api/v2/alerts")
      .with(query: { active: "true", silenced: "false", inhibited: "false" })
      .to_return(status: 200, body: [ { labels: { alertname: "DiskMissing" } } ].to_json)

    expect(described_class.new(configuration: configuration).firing_alerts).to eq([
      { "labels" => { "alertname" => "DiskMissing" } }
    ])
  end

  it "fails closed when Alertmanager returns a non-array payload" do
    stub_request(:get, "https://alerts.example.test/api/v2/alerts")
      .with(query: { active: "true", silenced: "false", inhibited: "false" })
      .to_return(status: 200, body: { error: "not ready" }.to_json)

    expect {
      described_class.new(configuration: configuration).firing_alerts
    }.to raise_error(AlertmanagerInvestigations::Client::Error, /expected Array/)
  end

  it "fails closed when Alertmanager returns non-object alert entries" do
    stub_request(:get, "https://alerts.example.test/api/v2/alerts")
      .with(query: { active: "true", silenced: "false", inhibited: "false" })
      .to_return(status: 200, body: [ "not an alert" ].to_json)

    expect {
      described_class.new(configuration: configuration).firing_alerts
    }.to raise_error(AlertmanagerInvestigations::Client::Error, /non-object entries/)
  end
end
