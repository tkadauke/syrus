require "rails_helper"
require "webmock/rspec"

RSpec.describe "OCI registry configuration, diagnostics, and workload isolation" do
  let(:env) do
    { "SYRUS_RUNTIME_IMAGE_REGISTRY_URL" => "https://registry.test",
      "SYRUS_RUNTIME_IMAGE_REGISTRY_BUILDER_USERNAME" => "b", "SYRUS_RUNTIME_IMAGE_REGISTRY_BUILDER_PASSWORD" => "s3cret-b",
      "SYRUS_RUNTIME_IMAGE_REGISTRY_WORKER_USERNAME" => "w", "SYRUS_RUNTIME_IMAGE_REGISTRY_WORKER_PASSWORD" => "s3cret-w" }
  end

  it "is absent without a registry URL" do
    expect(RuntimeImages::OciRegistry::Configuration.from_env({})).to be_nil
    expect(RuntimeImages::OciRegistry.provider_from_env({})).to be_nil
  end

  it "never prints secrets and rejects urls with embedded credentials" do
    config = RuntimeImages::OciRegistry::Configuration.from_env(env)
    expect(config.inspect).not_to include("s3cret")
    expect(config.credential_for(:builder).inspect).not_to include("s3cret")
    expect { RuntimeImages::OciRegistry::Configuration.new(url: "https://u:p@x.test", credentials: {}) }
      .to raise_error(RuntimeImages::OciRegistry::Configuration::Invalid)
    expect { config.credential_for(:admin) }.to raise_error(RuntimeImages::OciRegistry::Configuration::Invalid)
  end

  it "scrubs registry settings from workload environments" do
    scrubbed = RuntimeImages::OciRegistry::WorkloadEnvironment.scrub(env.merge("PATH" => "/bin"))
    expect(scrubbed).to eq("PATH" => "/bin")
    inherited = RuntimeImages::OciRegistry::WorkloadEnvironment.scrub({ "A" => "1" }, inherit: true, source: env)
    expect(inherited["SYRUS_RUNTIME_IMAGE_REGISTRY_BUILDER_PASSWORD"]).to be_nil
    expect(inherited).to have_key("SYRUS_RUNTIME_IMAGE_REGISTRY_BUILDER_PASSWORD")
  end

  it "scrubs registry settings from the environment a ProcessRunner passes to workloads" do
    Dir.mktmpdir do |dir|
      runner = ProcessRunner.new(env: env.merge("PATH" => "/bin"), command: ["true"], mounts: ProcessRunner.mounts(dir),
                                 network: "agent", timeout: 5)
      expect(runner.instance_variable_get(:@env)).to eq("PATH" => "/bin")
    end
  end

  describe RuntimeImages::OciRegistry::Diagnostics do
    let(:provider) { RuntimeImages::OciRegistry.provider_from_env(env) }

    it "reports per-role results, flags missing roles, and redacts secrets" do
      stub_request(:get, "https://registry.test/v2/").with { |r| r.headers["Authorization"].nil? }
        .to_return(status: 401, headers: { "WWW-Authenticate" => 'Bearer realm="https://registry.test/token",service="registry"' })
      stub_request(:get, "https://registry.test/token").with(query: hash_including({})).to_return do |req|
        user = Base64.decode64(req.headers["Authorization"].split.last).split(":").first
        user == "b" ? { status: 200, body: { token: "t" }.to_json } : { status: 403, body: "s3cret-w" }
      end
      stub_request(:get, "https://registry.test/v2/").with(headers: { "Authorization" => "Bearer t" }).to_return(status: 200)
      diagnostics = described_class.new(provider)
      checks = diagnostics.run.index_by(&:name)
      expect(checks["builder credential"].status).to eq(:ok)
      expect(checks["worker credential"].status).to eq(:fail)
      expect(checks["admin credential"].detail).to include("not configured")
      expect(checks.values.map(&:detail).join).not_to include("s3cret")
      expect(diagnostics.ok?(checks.values)).to be(false)
    end
  end
end
