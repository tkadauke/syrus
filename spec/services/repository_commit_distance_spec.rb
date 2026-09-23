require "rails_helper"

RSpec.describe RepositoryCommitDistance do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user) }
  let(:bare_clone) { instance_double(RepositoryBareClone) }

  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    original_registry = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    described_class.declare_metrics!
    example.run
  ensure
    Rails.cache = original_cache
    Syrus::Metrics.instance_variable_set(:@registry, original_registry)
  end

  def lookups
    Syrus::Metrics.counter(:syrus_repository_commit_distance_lookups_total).samples
      .to_h { |labels, value| [ labels[:outcome], value ] }
  end

  subject(:distance) { described_class.new(repository, bare_clone: bare_clone) }

  before do
    allow(bare_clone).to receive(:sync!)
    allow(RepositoryBareClone).to receive(:path_for).with(repository).and_return(
      Pathname.new(Dir.mktmpdir("syrus-commit-distance-lock"))
    )
  end

  describe "#commits_behind" do
    it "returns nil without touching the bare clone when base_sha is blank" do
      expect(bare_clone).not_to receive(:sync!)

      expect(distance.commits_behind(base_sha: "", head_sha: "head", user: user)).to be_nil
    end

    it "returns nil without touching the bare clone when head_sha is blank" do
      expect(bare_clone).not_to receive(:sync!)

      expect(distance.commits_behind(base_sha: "base", head_sha: "", user: user)).to be_nil
    end

    it "refreshes and computes on the first lookup for a SHA tuple" do
      allow(bare_clone).to receive(:commits_behind).with(head_sha: "head", base_sha: "base").and_return(3)

      result = distance.commits_behind(base_sha: "base", head_sha: "head", user: user)

      expect(result).to eq(3)
      expect(bare_clone).to have_received(:sync!).with(user: user).once
      expect(lookups["cache_miss"]).to eq(1)
      expect(lookups["refreshed"]).to eq(1)
    end

    it "reuses the cached distance for the same (repository, base_sha, head_sha) tuple without refreshing again" do
      allow(bare_clone).to receive(:commits_behind).with(head_sha: "head", base_sha: "base").and_return(3)
      distance.commits_behind(base_sha: "base", head_sha: "head", user: user)

      result = described_class.new(repository, bare_clone: bare_clone)
        .commits_behind(base_sha: "base", head_sha: "head", user: user)

      expect(result).to eq(3)
      expect(bare_clone).to have_received(:sync!).once
      expect(lookups["cache_hit"]).to eq(1)
    end

    it "does not cache a nil distance, so it recomputes (but does not re-refresh) on the next lookup" do
      allow(bare_clone).to receive(:commits_behind).and_return(nil)

      distance.commits_behind(base_sha: "base", head_sha: "head", user: user)
      distance.commits_behind(base_sha: "base", head_sha: "head", user: user)

      expect(bare_clone).to have_received(:commits_behind).twice
      expect(bare_clone).to have_received(:sync!).once
      expect(lookups["cache_miss"]).to eq(2)
    end

    it "does not refresh again for a different SHA tuple within the freshness window" do
      allow(bare_clone).to receive(:commits_behind).with(head_sha: "head", base_sha: "base").and_return(3)
      allow(bare_clone).to receive(:commits_behind).with(head_sha: "head2", base_sha: "base2").and_return(1)

      distance.commits_behind(base_sha: "base", head_sha: "head", user: user)
      distance.commits_behind(base_sha: "base2", head_sha: "head2", user: user)

      expect(bare_clone).to have_received(:sync!).once
      expect(lookups["refreshed"]).to eq(1)
      expect(lookups["cache_miss"]).to eq(2)
    end

    it "refreshes again once the freshness window has elapsed" do
      allow(bare_clone).to receive(:commits_behind).with(head_sha: "head", base_sha: "base").and_return(3)
      allow(bare_clone).to receive(:commits_behind).with(head_sha: "head2", base_sha: "base2").and_return(1)

      distance.commits_behind(base_sha: "base", head_sha: "head", user: user)
      travel_to(described_class::REFRESH_FRESHNESS_WINDOW.from_now + 1.second) do
        distance.commits_behind(base_sha: "base2", head_sha: "head2", user: user)
      end

      expect(bare_clone).to have_received(:sync!).twice
      expect(lookups["refreshed"]).to eq(2)
    end

    it "coalesces a concurrent refresh instead of launching a second fetch" do
      sync_started = Queue.new
      release_sync = Queue.new
      allow(bare_clone).to receive(:sync!) do
        sync_started << true
        release_sync.pop
      end
      allow(bare_clone).to receive(:commits_behind).with(head_sha: "head", base_sha: "base").and_return(3)
      allow(bare_clone).to receive(:commits_behind).with(head_sha: "head2", base_sha: "base2").and_return(1)

      first = Thread.new { distance.commits_behind(base_sha: "base", head_sha: "head", user: user) }
      sync_started.pop

      second_distance = described_class.new(repository, bare_clone: bare_clone)
      second = Thread.new { second_distance.commits_behind(base_sha: "base2", head_sha: "head2", user: user) }
      sleep 0.05
      release_sync << true

      expect(first.value).to eq(3)
      expect(second.value).to eq(1)
      expect(bare_clone).to have_received(:sync!).once
      expect(lookups["coalesced_wait"]).to eq(1)
    end
  end
end
