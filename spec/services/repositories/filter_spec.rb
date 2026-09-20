require "rails_helper"

RSpec.describe Repositories::Filter do
  let(:user) { Factories.user }

  describe ".tree_from_params" do
    it "translates legacy dropdown params into a flat AND-of-chips tree" do
      tree = described_class.tree_from_params({ github_owner: "acme", health: "broken", agent_provider: "codex" })

      expect(tree["and"]).to contain_exactly(
        { "field" => "github_owner", "op" => "is", "value" => "acme" },
        { "field" => "health", "op" => "is", "value" => "broken" },
        { "field" => "agent_provider", "op" => "is", "value" => "codex" }
      )
    end

    it "translates the slug/q/search text params into a contains chip" do
      expect(described_class.tree_from_params({ slug: "widgets" })["and"]).to contain_exactly(
        { "field" => "slug", "op" => "contains", "value" => "widgets" }
      )
    end

    it "translates has_open_jobs/archived booleans" do
      tree = described_class.tree_from_params({ has_open_jobs: "true", archived: "true" })

      expect(tree["and"]).to contain_exactly(
        { "field" => "has_open_jobs", "op" => "is", "value" => true },
        { "field" => "archived", "op" => "is", "value" => true }
      )
    end

    it "ignores has_open_jobs/archived when explicitly false" do
      expect(described_class.tree_from_params({ has_open_jobs: "false", archived: "false" })["and"]).to eq([])
    end

    it "returns an empty AND tree when no legacy params are present" do
      expect(described_class.tree_from_params({})).to eq("and" => [])
    end
  end

  describe ".from_params" do
    it "ANDs a given smart folder's tree in unconditionally" do
      folder_tree = { "and" => [ { "field" => "agent_provider", "op" => "is", "value" => "codex" } ] }
      smart_folder = instance_double(SmartFolder, filter: folder_tree)

      combined = described_class.from_params({}, smart_folder: smart_folder, user: user).to_h
      expect(combined["and"]).to contain_exactly(a_hash_including("field" => "agent_provider", "value" => "codex"))
    end

    # Callers must resolve `smart_folder:` through .smart_folder_floor first
    # (see that describe block) -- from_params itself always ANDs whatever
    # smart_folder it's given.
    it "combines with explicit legacy params instead of replacing them" do
      folder_tree = { "and" => [ { "field" => "archived", "op" => "is", "value" => true } ] }
      smart_folder = instance_double(SmartFolder, filter: folder_tree)

      combined = described_class.from_params({ agent_provider: "claude" }, smart_folder: smart_folder, user: user).to_h
      expect(combined["and"]).to contain_exactly(
        a_hash_including("field" => "archived", "value" => true),
        a_hash_including("field" => "agent_provider", "value" => "claude")
      )
    end
  end

  describe ".smart_folder_floor" do
    it "returns nil when no smart folder is active" do
      expect(described_class.smart_folder_floor({}, nil, user: user)).to be_nil
    end

    it "keeps the smart folder as the floor when no legacy param overrides it" do
      smart_folder = instance_double(SmartFolder, filter: { "and" => [] })

      expect(described_class.smart_folder_floor({}, smart_folder, user: user)).to eq(smart_folder)
    end

    it "drops the floor once an explicit legacy param is present" do
      smart_folder = instance_double(SmartFolder, filter: { "and" => [] })

      expect(described_class.smart_folder_floor({ health: "broken" }, smart_folder, user: user)).to be_nil
    end
  end

  describe "#apply" do
    let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", agent_provider: "codex") }
    let(:other) { Factories.repository(user: user, owner: "acme", name: "api", agent_provider: "claude") }

    it "filters by slug, owner, agent_provider, and archived" do
      other.archive!
      filter = described_class.from_params({ agent_provider: "codex" }, user: user)

      expect(filter.apply([ repository, other ])).to contain_exactly(repository)
    end

    it "filters has_open_jobs using preloaded counts" do
      filter = described_class.from_params({ has_open_jobs: "true" }, user: user)

      expect(filter.apply([ repository, other ], open_jobs_counts: { repository.id => 2 })).to contain_exactly(repository)
    end

    it "filters last_job_activity_at within_last using preloaded activity" do
      tree = { "and" => [ { "field" => "last_job_activity_at", "op" => "within_last", "value" => { "n" => 30, "unit" => "days" } } ] }
      filter = described_class.from_tree(tree, user: user)

      result = filter.apply(
        [ repository, other ],
        last_job_activity_by_id: { repository.id => 1.day.ago, other.id => 60.days.ago }
      )

      expect(result).to contain_exactly(repository)
    end

    it "is inactive and a no-op when the tree has no chips" do
      filter = described_class.from_tree({ "and" => [] }, user: user)

      expect(filter).not_to be_active
      expect(filter.apply([ repository, other ])).to contain_exactly(repository, other)
    end
  end
end
