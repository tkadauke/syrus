require "rails_helper"

RSpec.describe PluginRuntime::Client do
  let(:client) { described_class.new(url: "http://plugin-runtime:8080", token: "secret-token") }
  let(:spec) { { "plugin" => "git_mirror", "image" => "ghcr.io/tkadauke/x:1", "internal_port" => 8080 } }

  it "puts the spec with the bearer token and returns the status" do
    stub = stub_request(:put, "http://plugin-runtime:8080/v1/services/git-mirror")
      .with(headers: { "Authorization" => "Bearer secret-token", "Content-Type" => "application/json" }, body: spec.to_json)
      .to_return(status: 202, body: { service: "git-mirror", state: "pulling" }.to_json)

    expect(client.ensure_service("git-mirror", spec)).to include("state" => "pulling")
    expect(stub).to have_been_requested
  end

  # Refusals are the contributing plugin's bug and must not be retried as if
  # they were transient.
  it "raises Refused for a policy refusal and for a field the manager does not model" do
    stub_request(:put, %r{/v1/services/git-mirror}).to_return(status: 422, body: { error: "not in the allowlist" }.to_json)
    expect { client.ensure_service("git-mirror", spec) }.to raise_error(described_class::Refused, /allowlist/)

    stub_request(:put, %r{/v1/services/git-mirror}).to_return(status: 400, body: { error: "unknown field \"privileged\"" }.to_json)
    expect { client.ensure_service("git-mirror", spec) }.to raise_error(described_class::Refused, /privileged/)
  end

  it "raises Unavailable when the manager cannot be reached or fails" do
    stub_request(:get, %r{/v1/services}).to_raise(Errno::ECONNREFUSED)
    expect { client.list }.to raise_error(described_class::Unavailable, /unreachable/)

    stub_request(:get, %r{/v1/services}).to_return(status: 502, body: { error: "daemon down" }.to_json)
    expect { client.list }.to raise_error(described_class::Unavailable, /502/)
  end

  # A wrong token is an operator mistake, not a plugin bug: it must not be
  # mistaken for a refusal that blames the service's spec.
  it "treats a rejected token as unavailable, not as a refusal" do
    stub_request(:get, %r{/v1/services}).to_return(status: 401, body: { error: "missing or invalid bearer token" }.to_json)

    expect { client.list }.to raise_error(described_class::Unavailable, /401/)
  end

  it "keeps volumes on remove unless purge is asked for" do
    keep = stub_request(:delete, "http://plugin-runtime:8080/v1/services/git-mirror").to_return(status: 204)
    purge = stub_request(:delete, "http://plugin-runtime:8080/v1/services/git-mirror?purge=true").to_return(status: 204)

    client.remove("git-mirror")
    client.remove("git-mirror", purge: true)

    expect(keep).to have_been_requested.once
    expect(purge).to have_been_requested.once
  end

  it "escapes the service name in the path" do
    stub = stub_request(:get, "http://plugin-runtime:8080/v1/services/a%2Fb").to_return(status: 200, body: "{}")

    client.status("a/b")

    expect(stub).to have_been_requested
  end
end
