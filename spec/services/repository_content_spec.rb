require "rails_helper"

RSpec.describe RepositoryContent do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  # A scripted provider: each operation either returns its value or raises.
  def provider_class(key, role: :upstream, available: true, resolve: nil, tree: nil, read: nil, changes: nil, tree_sha: nil, log: [])
    Class.new do
      include Syrus::Plugin::RepositoryContentProvider

      define_singleton_method(:provider_key) { key }
      define_singleton_method(:display_name) { key.to_s.titleize }
      define_singleton_method(:role) { role }
      define_singleton_method(:available_for?) { |_repository| available }
      define_singleton_method(:build) { |repository:, user:| new }
      define_singleton_method(:name) { "#{key.to_s.camelize}Provider" }

      answer = lambda do |operation, script, *args|
        log << [ key, operation, *args ]
        value = script.respond_to?(:call) ? script.call(*args) : script
        raise value if value.is_a?(Exception)

        value
      end

      define_method(:resolve) { |ref, max_age:| answer.call(:resolve, resolve, ref, max_age) }
      define_method(:tree) { |id| answer.call(:tree, tree, id) }
      define_method(:read) { |id, path| answer.call(:read, read, id, path) }
      if changes
        define_method(:changes) { |base, head, patch: false| answer.call(:changes, changes, base, head, patch) }
      end
      if tree_sha
        define_method(:tree_sha) { |id| answer.call(:tree_sha, tree_sha, id) }
      end
    end
  end

  def revision(id = "a" * 40) = RepositoryContent::Revision.new(id: id)

  def blob(path, bytes = "content") = RepositoryContent::Blob.new(path: path, bytes: bytes)

  let(:memory_cache) { ActiveSupport::Cache::MemoryStore.new }

  def with_memory_cache
    allow(Rails).to receive(:cache).and_return(memory_cache)
  end

  describe ".provider_classes_for" do
    it "orders replicas before upstreams and skips providers that do not apply" do
      upstream = provider_class(:upstream)
      replica = provider_class(:replica, role: :replica)
      elsewhere = provider_class(:elsewhere, available: false)
      described_class.provider_classes_override = [ upstream, elsewhere, replica ]

      expect(described_class.provider_classes_for(repository)).to eq([ replica, upstream ])
    end
  end

  describe "the provider chain" do
    let(:log) { [] }

    it "falls through Unavailable, Unsupported, and UnknownRevision to the next provider" do
      described_class.provider_classes_override = [
        provider_class(:down, role: :replica, read: RepositoryContent::Unavailable.new("503"), log: log),
        provider_class(:cannot, role: :replica, read: RepositoryContent::Unsupported.new("no"), log: log),
        provider_class(:stale, role: :replica, read: RepositoryContent::UnknownRevision.new("not fetched"), log: log),
        provider_class(:github, read: blob("a.txt", "hello"), log: log)
      ]

      result = described_class.for(repository, user: user).read(revision, "a.txt")

      expect(result.text).to eq("hello")
      expect(log.map(&:first)).to eq(%i[down cannot stale github])
    end

    it "stops at NotFound: a known revision without the path is a final answer" do
      described_class.provider_classes_override = [
        provider_class(:mirror, role: :replica, read: RepositoryContent::NotFound.new("absent"), log: log),
        provider_class(:github, read: blob("a.txt"), log: log)
      ]

      expect { described_class.for(repository, user: user).read(revision, "a.txt") }.to raise_error(RepositoryContent::NotFound)
      expect(log.map(&:first)).to eq([ :mirror ])
    end

    it "treats an unexpected exception as Unavailable and moves on" do
      described_class.provider_classes_override = [
        provider_class(:buggy, role: :replica, read: ->(*) { raise Errno::ECONNREFUSED }, log: log),
        provider_class(:github, read: blob("a.txt", "ok"), log: log)
      ]

      expect(described_class.for(repository, user: user).read(revision, "a.txt").text).to eq("ok")
    end

    it "raises the last fall-through error when nobody can answer" do
      described_class.provider_classes_override = [
        provider_class(:mirror, role: :replica, read: RepositoryContent::UnknownRevision.new("not fetched")),
        provider_class(:github, read: RepositoryContent::Unavailable.new("rate limited"))
      ]

      expect { described_class.for(repository, user: user).read(revision, "a.txt") }
        .to raise_error(RepositoryContent::Unavailable, "rate limited")
    end

    # A partial answer falls through like any Unsupported, but when nobody
    # can do better it is what the caller gets -- a display caller can show
    # it, flagged, where an Unavailable would leave it nothing.
    it "prefers a truncated partial answer over a later outage" do
      partial = [ RepositoryContent::Entry.new(path: "a.rb") ]
      described_class.provider_classes_override = [
        provider_class(:mirror, role: :replica, tree: RepositoryContent::Unavailable.new("down")),
        provider_class(:github, tree: RepositoryContent::Truncated.new("too big", partial: partial))
      ]

      expect { described_class.for(repository, user: user).tree(revision) }
        .to raise_error(RepositoryContent::Truncated) { |error| expect(error.partial).to eq(partial) }
    end

    it "raises NoProvider, an Unavailable, when nothing serves the repository" do
      described_class.provider_classes_override = [ provider_class(:elsewhere, available: false) ]

      expect { described_class.for(repository, user: user).read(revision, "a.txt") }
        .to raise_error(RepositoryContent::NoProvider) { |error| expect(error).to be_a(RepositoryContent::Unavailable) }
    end

    it "skips a provider whose build returns nil" do
      unbuildable = provider_class(:no_credentials)
      unbuildable.define_singleton_method(:build) { |repository:, user:| nil }
      described_class.provider_classes_override = [ unbuildable, provider_class(:github, read: blob("a.txt", "ok")) ]

      expect(described_class.for(repository, user: user).read(revision, "a.txt").text).to eq("ok")
    end
  end

  describe "#resolve" do
    let(:calls) { [] }

    before do
      with_memory_cache
      described_class.provider_classes_override = [
        provider_class(:github, resolve: ->(ref, _max_age) { calls << ref; RepositoryContent::Revision.new(id: "sha-#{calls.size}") })
      ]
    end

    it "returns a Revision carrying the ref it was resolved from" do
      result = described_class.for(repository, user: user).resolve("main")

      expect(result).to have_attributes(id: "sha-1", ref: "main")
      expect(result.observed_at).to be_within(1.second).of(Time.current)
    end

    it "reuses a resolution younger than max_age" do
      content = described_class.for(repository, user: user)
      content.resolve("main")

      expect(content.resolve("main").id).to eq("sha-1")
      expect(calls.size).to eq(1)
    end

    it "asks again once the resolution is older than max_age" do
      content = described_class.for(repository, user: user)
      content.resolve("main")

      travel 61.seconds do
        expect(content.resolve("main").id).to eq("sha-2")
      end
    end

    it "always asks the chain for max_age: 0" do
      content = described_class.for(repository, user: user)
      content.resolve("main")

      expect(content.resolve("main", max_age: 0).id).to eq("sha-2")
    end
  end

  describe "#read" do
    it "caches reads at a revision, including confirmed absences" do
      with_memory_cache
      log = []
      described_class.provider_classes_override = [
        provider_class(:github, log: log, read: ->(_id, path) { path == "a.txt" ? blob("a.txt", "hello") : RepositoryContent::NotFound.new(path) })
      ]
      content = described_class.for(repository, user: user)

      2.times { expect(content.read(revision, "a.txt").text).to eq("hello") }
      2.times { expect(content.read_if_present(revision, "missing.txt")).to be_nil }

      expect(log.map { |entry| entry.last }).to eq([ "a.txt", "missing.txt" ])
    end

    it "does not cache failures to look" do
      with_memory_cache
      attempts = 0
      described_class.provider_classes_override = [
        provider_class(:github, read: ->(*) { (attempts += 1) == 1 ? RepositoryContent::Unavailable.new("503") : blob("a.txt") })
      ]
      content = described_class.for(repository, user: user)

      expect { content.read(revision, "a.txt") }.to raise_error(RepositoryContent::Unavailable)
      expect(content.read(revision, "a.txt").text).to eq("content")
    end

    it "truncates to max_bytes without losing the full size or corrupting binary bytes" do
      bytes = "\xFF\xD8\xFF\xE0binary".b
      described_class.provider_classes_override = [ provider_class(:github, read: blob("image.jpg", bytes)) ]

      result = described_class.for(repository, user: user).read(revision, "image.jpg", max_bytes: 3)

      expect(result.bytes).to eq("\xFF\xD8\xFF".b)
      expect(result).to have_attributes(size: bytes.bytesize, truncated: true)
    end

    it "requires a Revision so a moving branch name can never be cached as a fixed point" do
      described_class.provider_classes_override = [ provider_class(:github, read: blob("a.txt")) ]

      expect { described_class.for(repository, user: user).read("main", "a.txt") }.to raise_error(ArgumentError, /Revision/)
    end

    it "strips a leading slash from paths" do
      log = []
      described_class.provider_classes_override = [ provider_class(:github, read: blob("a.txt"), log: log) ]

      described_class.for(repository, user: user).read(revision, "/a.txt")

      expect(log.last.last).to eq("a.txt")
    end
  end

  describe "#tree and #files" do
    let(:entries) do
      %w[.syrus.yml app/models/user.rb docs/guide/intro.md docs/index.md package.json web/package.json]
        .map { |path| RepositoryContent::Entry.new(path: path) }
    end

    before do
      described_class.provider_classes_override = [
        provider_class(:github, tree: entries, read: ->(_id, path) { blob(path, "body of #{path}") })
      ]
    end

    it "narrows the tree with the core glob dialect" do
      content = described_class.for(repository, user: user)

      expect(content.tree(revision, glob: "**/package.json").map(&:path)).to eq(%w[package.json web/package.json])
      expect(content.tree(revision, glob: "docs/**").map(&:path)).to eq(%w[docs/guide/intro.md docs/index.md])
      expect(content.tree(revision, glob: "*.{yml,yaml}").map(&:path)).to eq(%w[.syrus.yml])
    end

    it "reads every matching file" do
      result = described_class.for(repository, user: user).files(revision, glob: "**/package.json")

      expect(result.transform_values(&:text)).to eq(
        "package.json" => "body of package.json",
        "web/package.json" => "body of web/package.json"
      )
    end

    it "refuses a pattern that matches more files than max_files" do
      expect { described_class.for(repository, user: user).files(revision, glob: "**", max_files: 2) }
        .to raise_error(ArgumentError, /max_files/)
    end
  end

  describe "#changes" do
    it "is Unsupported by default, so the chain can move on to a provider that compares" do
      change = RepositoryContent::Change.new(path: "a.rb", status: "modified")
      described_class.provider_classes_override = [
        provider_class(:mirror, role: :replica),
        provider_class(:github, changes: [ change ])
      ]

      result = described_class.for(repository, user: user).changes(base: revision("b" * 40), head: revision)

      expect(result).to eq([ change ])
    end
  end

  describe "#tree_sha" do
    it "is Unsupported by default, so the chain can move on to a provider that answers" do
      described_class.provider_classes_override = [
        provider_class(:mirror, role: :replica),
        provider_class(:github, tree_sha: "tree-abc")
      ]

      expect(described_class.for(repository, user: user).tree_sha(revision)).to eq("tree-abc")
    end

    it "caches the answer per revision" do
      with_memory_cache
      log = []
      described_class.provider_classes_override = [ provider_class(:github, tree_sha: "tree-abc", log: log) ]
      content = described_class.for(repository, user: user)

      2.times { expect(content.tree_sha(revision)).to eq("tree-abc") }

      expect(log.size).to eq(1)
    end
  end

  describe ".upstream_source_for" do
    def source(url) = RepositoryContent::Source.new(vcs: "git", url: url, password: "secret")

    it "asks upstreams in order and skips replicas, failures, and those with nothing to say" do
      replica = provider_class(:mirror, role: :replica)
      replica.define_singleton_method(:upstream_source) { |**| raise "replicas are never asked" }
      silent = provider_class(:silent)
      silent.define_singleton_method(:upstream_source) { |**| nil }
      broken = provider_class(:broken)
      broken.define_singleton_method(:upstream_source) { |**| raise Octokit::BadGateway }
      github = provider_class(:github)
      answer = source("https://example.test/#{repository.id}.git")
      github.define_singleton_method(:upstream_source) { |repository:, user:| answer }
      described_class.provider_classes_override = [ replica, silent, broken, github ]

      expect(described_class.upstream_source_for(repository).url).to eq("https://example.test/#{repository.id}.git")
    end

    it "is nil when no upstream can say" do
      described_class.provider_classes_override = [ provider_class(:github) ]

      expect(described_class.upstream_source_for(repository)).to be_nil
    end

    it "never shows the credential when inspected" do
      expect(source("https://example.test/a.git").inspect).not_to include("secret")
    end
  end

  describe "the reads counter" do
    around do |example|
      original = Syrus::Metrics.registry
      Syrus::Metrics.reset!
      RepositoryContent.declare_metrics!
      example.run
    ensure
      Syrus::Metrics.instance_variable_set(:@registry, original)
    end

    def reads
      Syrus::Metrics.counter(:syrus_repository_content_reads_total).samples
        .to_h { |labels, value| [ labels.values_at(:provider, :kind, :outcome).join("/"), value ] }
    end

    # The question it exists to answer: did the mirror serve this, or did the
    # read fall through to the host?
    it "counts each provider asked and what it said" do
      described_class.provider_classes_override = [
        provider_class(:git_mirror, role: :replica, read: ->(_id, path) { path == "a" ? blob("a") : RepositoryContent::UnknownRevision.new("lagging") }),
        provider_class(:github, read: ->(_id, path) { path == "gone" ? RepositoryContent::NotFound.new(path) : blob(path) })
      ]
      content = described_class.for(repository, user: user)

      content.read(revision, "a")
      content.read(revision, "b")
      content.read_if_present(revision, "gone")

      expect(reads).to eq(
        "git_mirror/read/answered" => 1,
        "git_mirror/read/unknown_revision" => 2,
        "github/read/answered" => 1,
        "github/read/not_found" => 1
      )
    end

    it "counts cache hits, outages, and repositories nothing serves" do
      with_memory_cache
      described_class.provider_classes_override = [
        provider_class(:github, read: blob("a"), tree: RepositoryContent::Unavailable.new("rate limited"))
      ]
      content = described_class.for(repository, user: user)
      2.times { content.read(revision, "a") }
      expect { content.tree(revision) }.to raise_error(RepositoryContent::Unavailable)

      described_class.provider_classes_override = []
      expect { described_class.for(repository, user: user).tree(revision) }.to raise_error(RepositoryContent::NoProvider)

      expect(reads).to eq(
        "github/read/answered" => 1,
        "cache/read/answered" => 1,
        "github/tree/unavailable" => 1,
        "none/tree/unavailable" => 1
      )
    end
  end

  describe RepositoryContent::Blob do
    it "holds binary bytes and decodes text leniently" do
      value = described_class.new(path: "a.txt", bytes: "caf\xC3\xA9 \xFF")

      expect(value.bytes.encoding).to eq(Encoding::BINARY)
      expect(value.text).to eq("café �")
      expect(value.size).to eq(7)
    end
  end

  describe RepositoryContent::Glob do
    it "matches dotfiles, nested directories, and alternatives" do
      expect(described_class.match?("*", ".syrus.yml")).to be(true)
      expect(described_class.match?("*", "app/a.rb")).to be(false)
      expect(described_class.match?("**/*.rb", "a.rb")).to be(true)
      expect(described_class.match?("**/*.rb", "app/models/a.rb")).to be(true)
      expect(described_class.match?("app/**", "app/models/a.rb")).to be(true)
      expect(described_class.match?("**", "app/models/a.rb")).to be(true)
      expect(described_class.match?("*.{yml,yaml}", "config.yaml")).to be(true)
      expect(described_class.match?([ "*.md", "*.rb" ], "a.rb")).to be(true)
    end
  end
end
