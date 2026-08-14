require "rails_helper"

RSpec.describe PreviewLogClient do
  let(:job) { Factories.job }

  def create_env(**attrs)
    PreviewEnvironment.create!({ job: job, state: "running", internal_host: "10.0.0.5" }.merge(attrs))
  end

  def control_url(env, lines:)
    "http://10.0.0.5:#{PreviewControlServer::PORT}/environments/#{env.id}/logs?lines=#{lines}"
  end

  it "returns parsed logs from the control endpoint" do
    env = create_env
    stub_request(:get, control_url(env, lines: 50)).to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { logs: [ { path: "log/development.log", content: "hi", missing: false } ] }.to_json
    )

    logs = described_class.call(env, lines: 50)

    expect(logs).to contain_exactly(
      have_attributes(path: "log/development.log", content: "hi", missing: false)
    )
  end

  it "raises Unavailable when the environment has no internal host" do
    env = create_env(internal_host: nil)

    expect { described_class.call(env, lines: 50) }.to raise_error(described_class::Unavailable)
  end

  it "raises Unavailable when the control endpoint times out" do
    env = create_env
    stub_request(:get, control_url(env, lines: 50)).to_timeout

    expect { described_class.call(env, lines: 50) }.to raise_error(described_class::Unavailable)
  end

  it "raises Unavailable when the control endpoint returns a non-success status" do
    env = create_env
    stub_request(:get, control_url(env, lines: 50)).to_return(status: 500, body: "boom")

    expect { described_class.call(env, lines: 50) }.to raise_error(described_class::Unavailable)
  end
end
