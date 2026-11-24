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

    def jwt(access)
      enc = ->(h) { Base64.urlsafe_encode64(h.to_json, padding: false) }
      [enc.call(alg: "none"), enc.call(access: access), "sig"].join(".")
    end

    def stub_challenge
      stub_request(:get, "https://registry.test/v2/").with { |r| r.headers["Authorization"].nil? }
        .to_return(status: 401, headers: { "WWW-Authenticate" => 'Bearer realm="https://registry.test/token",service="registry"' })
    end

    let(:probe) { "syrus/diagnostics/probe" }

    def stub_token(&block)
      stub_request(:get, "https://registry.test/token").with(query: hash_including({})).to_return(&block)
    end

    def stub_tags(status:, body: "")
      stub_request(:get, "https://registry.test/v2/#{probe}/tags/list").to_return(status: status, body: body)
    end

    it "reports per-role results, flags missing roles, and redacts secrets" do
      stub_challenge
      stub_token do |req|
        user = Base64.decode64(req.headers["Authorization"].split.last).split(":").first
        if user == "b"
          { status: 200, body: { token: jwt([{ "name" => probe, "actions" => %w[pull push] }]) }.to_json }
        else
          { status: 403, body: "s3cret-w" }
        end
      end
      stub_tags(status: 404, body: '{"errors":[{"code":"NAME_UNKNOWN"}]}')
      stub_request(:post, "https://registry.test/v2/#{probe}/blobs/uploads/")
        .to_return(status: 202, headers: { "Location" => "https://registry.test/v2/#{probe}/blobs/uploads/u1" })
      stub_request(:delete, "https://registry.test/v2/#{probe}/blobs/uploads/u1").to_return(status: 204)
      diagnostics = described_class.new(provider)
      checks = diagnostics.run.index_by(&:name)
      expect(checks["builder credential"].status).to eq(:ok)
      expect(checks["worker credential"].status).to eq(:fail)
      expect(checks["admin credential"].detail).to include("not configured")
      expect(checks.values.map(&:detail).join).not_to include("s3cret")
      expect(diagnostics.ok?(checks.values)).to be(false)
    end

    it "fails a role whose token lacks the requested actions even though /v2/ would answer 200" do
      stub_challenge
      stub_token { { status: 200, body: { token: jwt([{ "name" => probe, "actions" => ["pull"] }]) }.to_json } }
      stub_tags(status: 200, body: "{}")
      check = described_class.new(provider).run.find { |c| c.name == "builder credential" }
      expect(check.status).to eq(:fail)
      expect(check.detail).to include("push")
    end

    it "fails when the token claims the right actions but the registry rejects the bearer token" do
      stub_challenge
      stub_token { { status: 200, body: { token: jwt([{ "name" => probe, "actions" => %w[pull push] }]) }.to_json } }
      stub_request(:get, "https://registry.test/v2/#{probe}/tags/list")
        .to_return(status: 401, headers: { "WWW-Authenticate" => 'Bearer realm="https://registry.test/token",service="registry"' })
      check = described_class.new(provider).run.find { |c| c.name == "builder credential" }
      expect(check.status).to eq(:fail)
      expect(check.detail).to include("rejected")
    end

    it "fails an opaque token whose pull probe is a bare 404 that does not name the repository unknown" do
      stub_challenge
      stub_token { { status: 200, body: { token: "opaque" }.to_json } }
      stub_tags(status: 404, body: "not found")
      checks = described_class.new(provider).run.index_by(&:name)
      expect(checks["worker credential"].status).to eq(:fail)
      expect(checks["builder credential"].status).to eq(:fail)
    end

    it "verifies pull, and push via a cancelled upload, for opaque tokens" do
      stub_challenge
      stub_token { { status: 200, body: { token: "opaque" }.to_json } }
      stub_tags(status: 404, body: '{"errors":[{"code":"NAME_UNKNOWN"}]}')
      stub_request(:post, "https://registry.test/v2/#{probe}/blobs/uploads/")
        .to_return(status: 202, headers: { "Location" => "/v2/#{probe}/blobs/uploads/u1" })
      cancel = stub_request(:delete, "https://registry.test/v2/#{probe}/blobs/uploads/u1").to_return(status: 204)
      checks = described_class.new(provider).run.index_by(&:name)
      expect(checks["builder credential"].status).to eq(:ok)
      expect(checks["worker credential"].status).to eq(:ok)
      expect(cancel).to have_been_requested
    end

    context "when the probe upload cannot be cancelled" do
      before do
        stub_challenge
        stub_token { { status: 200, body: { token: "opaque" }.to_json } }
        stub_tags(status: 404, body: '{"errors":[{"code":"NAME_UNKNOWN"}]}')
      end

      def builder_check
        described_class.new(provider).run.find { |c| c.name == "builder credential" }
      end

      it "fails when the upload Location is missing" do
        stub_request(:post, "https://registry.test/v2/#{probe}/blobs/uploads/").to_return(status: 202)
        expect(builder_check.status).to eq(:fail)
        expect(builder_check.detail).to include("not cancelled")
      end

      it "fails when the upload Location points outside the probe repository" do
        stub_request(:post, "https://registry.test/v2/#{probe}/blobs/uploads/")
          .to_return(status: 202, headers: { "Location" => "/v2/other/blobs/uploads/u1" })
        expect(builder_check.status).to eq(:fail)
      end

      it "fails when the cancellation DELETE returns an error" do
        stub_request(:post, "https://registry.test/v2/#{probe}/blobs/uploads/")
          .to_return(status: 202, headers: { "Location" => "/v2/#{probe}/blobs/uploads/u1" })
        stub_request(:delete, "https://registry.test/v2/#{probe}/blobs/uploads/u1").to_return(status: 500)
        expect(builder_check.status).to eq(:fail)
        expect(builder_check.detail).to include("HTTP 500")
      end
    end

    it "fails a builder whose push is denied by the registry" do
      stub_challenge
      stub_token { { status: 200, body: { token: "opaque" }.to_json } }
      stub_tags(status: 200, body: "{}")
      stub_request(:post, "https://registry.test/v2/#{probe}/blobs/uploads/").to_return(status: 403)
      check = described_class.new(provider).run.find { |c| c.name == "builder credential" }
      expect(check.status).to eq(:fail)
      expect(check.detail).to include("push")
    end
  end
end
