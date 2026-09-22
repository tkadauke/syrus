require "rails_helper"

RSpec.describe GitMirror::ContentProvider do
  let(:endpoint) { "http://git-mirror:8080" }
  let(:repository) { Factories.repository }
  let(:base) { "#{endpoint}/v1/repositories/#{repository.id}" }
  let(:sha) { "a" * 40 }
  let(:token) { GitMirror::Configuration.token }
  let(:provider) { described_class.build(repository: repository, user: repository.user) }

  # An upstream that can hand the mirror credentials, as a hosting plugin would.
  let(:upstream) do
    Class.new do
      include Syrus::Plugin::RepositoryContentProvider

      def self.provider_key = "host"
      def self.display_name = "Host"
      def self.role = :upstream
      def self.available_for?(_repository) = true
      def self.upstream_source(**) = nil
    end
  end

  before do
    allow(PluginRuntime::Services).to receive(:endpoint_for).with("git-mirror").and_return(endpoint)
    RepositoryContent.provider_classes_override = [ described_class, upstream ]
  end

  def stub_mirror(path, query, status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    stub_request(:get, "#{base}/#{path}").with(query: query, headers: { "Authorization" => "Bearer #{token}" })
      .to_return(status: status, body: body, headers: headers)
  end

  def error(code) = { error: { code: code, message: code } }.to_json

  describe ".available_for?" do
    it "serves git repositories while the service is up and an upstream can feed it" do
      expect(described_class.available_for?(repository)).to be(true)
    end

    it "steps aside when the service is not available" do
      allow(PluginRuntime::Services).to receive(:endpoint_for).with("git-mirror").and_return(nil)

      expect(described_class.available_for?(repository)).to be(false)
      expect(described_class.build(repository: repository, user: repository.user)).to be_nil
    end

    it "steps aside when no upstream could keep it in sync" do
      RepositoryContent.provider_classes_override = [ described_class ]

      expect(described_class.available_for?(repository)).to be(false)
    end
  end

  it "resolves a ref, passing max_age through" do
    stub_mirror("resolve", { ref: "main", max_age: "0" }, body: { id: sha, observed_at: "2026-09-21T12:00:00Z" }.to_json)

    expect(provider.resolve("main", max_age: 0)).to have_attributes(id: sha, ref: "main", observed_at: Time.zone.parse("2026-09-21T12:00:00Z"))
  end

  it "lists a tree" do
    stub_mirror("tree", { revision: sha }, body: { entries: [
      { path: ".syrus.yml", type: "file", size: 9, content_id: "b1" },
      { path: "vendor/dep", type: "submodule", content_id: "c1" }
    ] }.to_json)

    expect(provider.tree(sha).map { |entry| [ entry.path, entry.type, entry.content_id ] })
      .to eq([ [ ".syrus.yml", "file", "b1" ], [ "vendor/dep", "submodule", "c1" ] ])
  end

  it "reads raw bytes" do
    stub_mirror("blob", { revision: sha, path: "logo.png" }, body: "\x89PNG".b, headers: { "X-Content-Id" => "b2" })

    expect(provider.read(sha, "logo.png")).to have_attributes(bytes: "\x89PNG".b, content_id: "b2", size: 4)
  end

  it "lists changes, and leaves patches to the host" do
    stub_mirror("changes", { base: "b" * 40, head: sha }, body: { changes: [ { path: "new.rb", status: "renamed", previous_path: "old.rb" } ] }.to_json)

    expect(provider.changes("b" * 40, sha).map(&:to_h)).to include(include(path: "new.rb", status: "renamed", previous_path: "old.rb"))
    expect { provider.changes("b" * 40, sha, patch: true) }.to raise_error(RepositoryContent::Unsupported)
  end

  describe "errors" do
    it "treats a missing file in a known commit as final" do
      stub_mirror("blob", { revision: sha, path: "gone" }, status: 404, body: error("not_found"))

      expect { provider.read(sha, "gone") }.to raise_error(RepositoryContent::NotFound)
    end

    it "lets the host answer for commits, repositories, and operations the mirror does not have" do
      stub_mirror("blob", { revision: sha, path: "a" }, status: 404, body: error("unknown_revision"))
      stub_mirror("tree", { revision: sha }, status: 404, body: error("unknown_repository"))
      stub_mirror("changes", { base: sha, head: sha }, status: 501, body: error("unsupported"))
      stub_mirror("resolve", { ref: "main", max_age: "60" }, status: 503, body: error("unavailable"))

      expect { provider.read(sha, "a") }.to raise_error(RepositoryContent::UnknownRevision)
      expect { provider.tree(sha) }.to raise_error(RepositoryContent::Unavailable)
      expect { provider.changes(sha, sha) }.to raise_error(RepositoryContent::Unsupported)
      expect { provider.resolve("main", max_age: 60) }.to raise_error(RepositoryContent::Unavailable)
    end

    it "treats an unreachable service as unavailable" do
      stub_request(:get, "#{base}/tree").with(query: { revision: sha }).to_raise(Errno::ECONNREFUSED)

      expect { provider.tree(sha) }.to raise_error(RepositoryContent::Unavailable)
    end
  end

  describe "after the mirror restarts" do
    let(:source) { RepositoryContent::Source.new(vcs: "git", url: "https://example.test/r.git", password: "short-lived") }

    # It serves from disk but has no credential until the next sync tick;
    # the first read re-registers the repository instead of waiting.
    it "registers the repository on the spot and asks again" do
      allow(RepositoryContent).to receive(:upstream_source_for).with(repository).and_return(source)
      register = stub_request(:put, base).to_return(status: 200, body: "{}")
      stub_mirror("resolve", { ref: "main", max_age: "60" }, status: 503, body: error("unregistered"))
        .then.to_return(status: 200, body: { id: sha, observed_at: "2026-09-22T02:30:00Z" }.to_json)

      expect(provider.resolve("main", max_age: 60).id).to eq(sha)
      expect(register).to have_been_requested.once
    end

    it "falls through to the host when there is nothing to register with" do
      allow(RepositoryContent).to receive(:upstream_source_for).and_return(nil)
      stub_mirror("tree", { revision: sha }, status: 503, body: error("unregistered"))

      expect { provider.tree(sha) }.to raise_error(RepositoryContent::Unavailable)
    end
  end

  # Replicas first: with the mirror answering, the host is never asked; when
  # the mirror cannot answer, the host is.
  it "sits in front of the upstream in the content chain" do
    host_reads = []
    reads = host_reads
    upstream.define_singleton_method(:build) { |**| Object.new.tap { |o| o.define_singleton_method(:read) { |_id, path| reads << path; RepositoryContent::Blob.new(path: path, bytes: "from host") } } }
    stub_mirror("blob", { revision: sha, path: "a" }, body: "from mirror")
    stub_mirror("blob", { revision: sha, path: "b" }, status: 404, body: error("unknown_revision"))
    content = RepositoryContent.for(repository)

    expect(content.read(content.revision(sha), "a").text).to eq("from mirror")
    expect(content.read(content.revision(sha), "b").text).to eq("from host")
    expect(host_reads).to eq([ "b" ])
  end
end
