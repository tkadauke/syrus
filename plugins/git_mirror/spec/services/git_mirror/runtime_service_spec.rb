require "rails_helper"

RSpec.describe GitMirror::RuntimeService do
  around do |example|
    original = ENV.to_h.slice("SYRUS_GIT_MIRROR_TOKEN", "SYRUS_GIT_MIRROR_IMAGE", "SYRUS_VERSION")
    example.run
  ensure
    %w[SYRUS_GIT_MIRROR_TOKEN SYRUS_GIT_MIRROR_IMAGE SYRUS_VERSION].each { |key| ENV[key] = original[key] }
  end

  it "declares a service Plugin Runtime can run" do
    expect(PluginRuntime::Service.implemented_by?(described_class)).to be(true)
    expect(described_class.service_name).to eq("git-mirror")
    expect(described_class.service_spec).to include(
      internal_port: 8080,
      volumes: [ { name: "data", mount_path: "/data" } ],
      healthcheck: { path: "/healthz" }
    )
  end

  it "runs the image from the same release as Syrus" do
    ENV["SYRUS_VERSION"] = "0.9.2"

    expect(described_class.service_spec[:image]).to eq("ghcr.io/tkadauke/syrus-plugin-git-mirror:0.9.2")
  end

  it "uses latest for builds without a release version and honours an explicit image" do
    ENV["SYRUS_VERSION"] = nil
    expect(described_class.service_spec[:image]).to end_with(":latest")

    ENV["SYRUS_GIT_MIRROR_IMAGE"] = "ghcr.io/tkadauke/syrus-plugin-git-mirror:pinned"
    expect(described_class.service_spec[:image]).to eq("ghcr.io/tkadauke/syrus-plugin-git-mirror:pinned")
  end

  it "hands the service a stable token that is long enough and not stored anywhere" do
    ENV["SYRUS_GIT_MIRROR_TOKEN"] = nil
    token = described_class.service_spec[:env]["GIT_MIRROR_TOKEN"]

    expect(token).to match(/\A\h{64}\z/)
    expect(described_class.service_spec[:env]["GIT_MIRROR_TOKEN"]).to eq(token)

    ENV["SYRUS_GIT_MIRROR_TOKEN"] = "operator-set-token-for-kubernetes-0123456789"
    expect(described_class.service_spec[:env]["GIT_MIRROR_TOKEN"]).to eq("operator-set-token-for-kubernetes-0123456789")
  end

  describe ".service_details" do
    let(:endpoint) { "http://git-mirror:8080" }
    let(:repository) { Factories.repository(owner: "acme", name: "widgets") }

    around do |example|
      original = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      example.run
    ensure
      Rails.cache = original
    end

    def stub_stats(repositories:, disk: { total_bytes: 100, free_bytes: 40, mirror_bytes: 10 })
      stub_request(:get, "#{endpoint}/v1/repositories").to_return(status: 200, body: { repositories: repositories, disk: disk }.to_json)
    end

    it "summarizes the mirror and lists repositories by name, largest first" do
      stub_stats(repositories: [
        { id: repository.id.to_s, size_bytes: 10, last_fetch_at: "2026-09-22T02:30:00Z", last_error: "" },
        { id: "999999", size_bytes: 20, last_error: "credential expired" }
      ])

      details = described_class.service_details(endpoint: endpoint)

      expect(details[:summary].map { |item| [ item[:label_key].split(".").last, item[:value] ] })
        .to eq([ [ "repositories", 2 ], [ "mirror_size", 10 ], [ "disk_free", 40 ], [ "disk_total", 100 ] ])
      expect(details[:table][:rows]).to eq([
        { repository: "#999999", size: 20, last_fetch_at: nil, last_maintenance_at: nil, error: "credential expired" },
        { repository: "acme/widgets", size: 10, last_fetch_at: "2026-09-22T02:30:00Z", last_maintenance_at: nil, error: nil }
      ])
    end

    it "is nil when the mirror cannot be reached" do
      stub_request(:get, "#{endpoint}/v1/repositories").to_raise(Errno::ECONNREFUSED)

      expect(described_class.service_details(endpoint: endpoint)).to be_nil
    end

    # One request per tick, however many gauges read it.
    it "shares one stats request between readers" do
      stats = stub_stats(repositories: [ { id: "1", size_bytes: 5 } ])
      allow(GitMirror::ContentProvider).to receive(:endpoint).and_return(endpoint)

      expect(GitMirror::Stats.repository_count).to eq(1)
      expect(GitMirror::Stats.disk("free_bytes")).to eq(40)
      expect(stats).to have_been_requested.once
    end
  end
end
