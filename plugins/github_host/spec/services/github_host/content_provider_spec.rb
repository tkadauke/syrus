require "rails_helper"

RSpec.describe GithubHost::ContentProvider do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:client) { instance_double(GithubClient) }
  let(:provider) { described_class.new(repository: repository, user: user, client: client) }
  let(:sha) { "a" * 40 }

  def rate_limited = Octokit::TooManyRequests.new

  describe ".build" do
    it "needs GitHub credentials" do
      expect(described_class.build(repository: repository, user: user)).to be_a(described_class)
      tokenless = Factories.user
      bare_repository = Factories.repository(user: tokenless)
      expect(described_class.build(repository: bare_repository, user: tokenless)).to be_nil
    end
  end

  it "registers as an upstream for git repositories" do
    expect(described_class.role).to eq(:upstream)
    expect(described_class.available_for?(repository)).to be(true)
    expect(Syrus::PluginRegistry.providers_for(:repository_content_provider)).to include(described_class)
  end

  describe "#resolve" do
    it "takes a commit SHA as already resolved, without asking GitHub" do
      expect(provider.resolve(sha.upcase, max_age: 0)).to have_attributes(id: sha)
    end

    it "resolves a branch to its commit" do
      allow(client).to receive(:commit_sha_for).with("acme/widgets", "main").and_return(sha)

      expect(provider.resolve("main", max_age: 60)).to have_attributes(id: sha, ref: "main")
    end

    it "reports an unknown ref as UnknownRevision and a rate limit as Unavailable" do
      allow(client).to receive(:commit_sha_for).with("acme/widgets", "gone").and_raise(Octokit::NotFound)
      allow(client).to receive(:commit_sha_for).with("acme/widgets", "main").and_raise(rate_limited)

      expect { provider.resolve("gone", max_age: 60) }.to raise_error(RepositoryContent::UnknownRevision)
      expect { provider.resolve("main", max_age: 60) }.to raise_error(RepositoryContent::Unavailable)
    end
  end

  describe "#tree" do
    it "maps files, symlinks, and submodules, and leaves directories out" do
      allow(client).to receive(:commit_tree_entries).with("acme/widgets", sha).and_return(
        truncated: false,
        entries: [
          { path: "lib", type: "tree", mode: "040000", size: nil, sha: "t" },
          { path: "lib/a.rb", type: "blob", mode: "100644", size: 12, sha: "b1" },
          { path: "current", type: "blob", mode: "120000", size: 5, sha: "b2" },
          { path: "vendor/dep", type: "commit", mode: "160000", size: nil, sha: "c1" }
        ]
      )

      expect(provider.tree(sha).map { |entry| [ entry.path, entry.type, entry.content_id ] }).to eq([
        [ "lib/a.rb", "file", "b1" ],
        [ "current", "symlink", "b2" ],
        [ "vendor/dep", "submodule", "c1" ]
      ])
    end

    it "refuses to pass off a truncated tree as complete" do
      allow(client).to receive(:commit_tree_entries).and_return(truncated: true, entries: [])

      expect { provider.tree(sha) }.to raise_error(RepositoryContent::Unsupported)
    end
  end

  describe "#read" do
    it "returns the file's bytes addressed by its blob SHA" do
      allow(client).to receive(:file_bytes_at).with("acme/widgets", ".syrus.yml", sha).and_return(bytes: "grade: []", size: 9, sha: "blob")

      expect(provider.read(sha, ".syrus.yml")).to have_attributes(text: "grade: []", size: 9, content_id: "blob")
    end

    it "separates a missing file (NotFound) from an unknown revision and an outage" do
      allow(client).to receive(:file_bytes_at).with("acme/widgets", "missing", sha).and_return(nil)
      allow(client).to receive(:file_bytes_at).with("acme/widgets", "a", "gone").and_raise(Octokit::NotFound)
      allow(client).to receive(:file_bytes_at).with("acme/widgets", "a", sha).and_raise(Octokit::BadGateway)

      expect { provider.read(sha, "missing") }.to raise_error(RepositoryContent::NotFound)
      expect { provider.read("gone", "a") }.to raise_error(RepositoryContent::UnknownRevision)
      expect { provider.read(sha, "a") }.to raise_error(RepositoryContent::Unavailable)
    end

    it "treats failing to get a client at all as Unavailable" do
      unclientable = described_class.new(repository: repository, user: user)
      allow(GithubClient).to receive(:for).and_raise(Faraday::ConnectionFailed, "boom")

      expect { unclientable.read(sha, "a") }.to raise_error(RepositoryContent::Unavailable)
    end
  end

  describe "#changes" do
    it "maps GitHub statuses onto the contract's" do
      allow(client).to receive(:compare_file_changes).with("acme/widgets", "base", "head").and_return(
        truncated: false,
        files: [
          { path: "new.rb", previous_path: "old.rb", status: "renamed", additions: 0, deletions: 0, patch: nil },
          { path: "gone.rb", previous_path: nil, status: "removed", additions: 0, deletions: 3, patch: "-x" },
          { path: "copy.rb", previous_path: nil, status: "copied", additions: 3, deletions: 0, patch: "+x" }
        ]
      )

      result = provider.changes("base", "head", patch: false)

      expect(result.map { |change| [ change.path, change.status, change.previous_path, change.patch ] }).to eq([
        [ "new.rb", "renamed", "old.rb", nil ],
        [ "gone.rb", "deleted", nil, nil ],
        [ "copy.rb", "added", nil, nil ]
      ])
    end

    it "refuses to pass off GitHub's 300-file cap as the whole change" do
      allow(client).to receive(:compare_file_changes).and_return(truncated: true, files: [])

      expect { provider.changes("base", "head") }.to raise_error(RepositoryContent::Unsupported, /300/)
    end
  end

  it "answers through RepositoryContent end to end" do
    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:commit_sha_for).and_return(sha)
    allow(client).to receive(:file_bytes_at).with("acme/widgets", ".syrus.yml", sha).and_return(bytes: "grade: []", size: 9, sha: "blob")

    content = RepositoryContent.for(repository, user: user)

    expect(content.read(content.resolve("main"), ".syrus.yml").text).to eq("grade: []")
  end
end
