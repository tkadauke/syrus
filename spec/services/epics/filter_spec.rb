require "rails_helper"

RSpec.describe Epics::Filter do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def filter_for(params, smart_folder: nil)
    described_class.from_params(params, smart_folder: smart_folder, user: user).to_h
  end

  describe ".from_params" do
    it "reads q= and treats it as the primary tree when nothing else is set" do
      tree = { "and" => [ { "field" => "state", "op" => "is", "value" => "ready" } ] }
      q = Filters::QueryParam.encode(tree)

      expect(filter_for({ q: q })).to eq(tree)
    end

    it "ANDs q= with the active smart folder's tree" do
      folder_tree = { "and" => [ { "field" => "state", "op" => "is", "value" => "in_progress" } ] }
      smart_folder = instance_double(SmartFolder, filter: folder_tree)
      extra = { "and" => [ { "field" => "title", "op" => "contains", "value" => "auth" } ] }
      q = Filters::QueryParam.encode(extra)

      result = filter_for({ q: q }, smart_folder: smart_folder)

      expect(result["and"]).to include(
        a_hash_including("field" => "state", "value" => "in_progress"),
        a_hash_including("field" => "title", "value" => "auth")
      )
    end

    it "ANDs q= with Epic legacy flat URL params" do
      q_tree = { "and" => [ { "field" => "title", "op" => "contains", "value" => "auth" } ] }
      q = Filters::QueryParam.encode(q_tree)

      result = filter_for({ q: q, state: "ready", repository_id: repo.id.to_s })

      expect(result["and"]).to include(
        a_hash_including("field" => "title", "value" => "auth"),
        a_hash_including("field" => "state", "value" => "ready"),
        a_hash_including("field" => "repository_id", "value" => repo.id.to_s)
      )
    end

    it "translates ActionController legacy params without requiring unrelated keys" do
      params = ActionController::Parameters.new(state: "done", repository_id: repo.id.to_s, kind: "issue")

      result = filter_for(params)

      expect(result["and"]).to contain_exactly(
        a_hash_including("field" => "state", "value" => "done"),
        a_hash_including("field" => "repository_id", "value" => repo.id.to_s)
      )
    end

    it "ignores a malformed q= without raising" do
      expect { filter_for({ q: "not!valid!base64" }) }.not_to raise_error
    end
  end

  describe ".from_tree" do
    it "builds a filter from an AST tree" do
      tree = { "and" => [ { "field" => "repository_id", "op" => "is", "value" => repo.id } ] }

      expect(described_class.from_tree(tree, user: user).to_h).to eq(
        "and" => [ { "field" => "repository_id", "op" => "is", "value" => repo.id } ]
      )
    end
  end

  describe "#apply" do
    it "passes subject: :epic to the filter compiler" do
      tree = { "and" => [ { "field" => "state", "op" => "is", "value" => "ready" } ] }
      filter = described_class.from_tree(tree, user: user)
      scope = Epic.where(repository: repo)

      expect(Filters::Compiler).to receive(:call).with(
        instance_of(Filters::Ast::AndNode),
        scope: scope,
        user: user,
        subject: :epic
      ).and_return(scope)

      expect(filter.apply(scope)).to eq(scope)
    end
  end

  describe "public helpers" do
    it "reports inactive empty filters" do
      filter = described_class.from_params({}, user: user)

      expect(filter).not_to be_active
      expect(filter).not_to be_pinned
    end

    it "reports active and pinned filters from chips anywhere in the tree" do
      tree = {
        "not" => {
          "field" => "attention",
          "op" => "is",
          "value" => "pinned"
        }
      }

      filter = described_class.from_tree(tree, user: user)

      expect(filter).to be_active
      expect(filter).to be_pinned
    end

    it "round-trips through the q= query param format" do
      tree = { "and" => [ { "field" => "state", "op" => "is", "value" => "backlog" } ] }
      filter = described_class.from_tree(tree, user: user)

      expect(Filters::QueryParam.decode(filter.to_query_param)).to eq(tree)
    end
  end
end
