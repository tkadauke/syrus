require "rails_helper"

RSpec.describe Filters::Chips::AdminUsers::Search do
  let(:user) { Factories.user }

  def apply(value, op: :contains)
    described_class.new(scope: User.all, op: op, value: value, user: user).apply
  end

  describe "#apply" do
    it "matches on name via User.search" do
      target = Factories.user(name: "Grace Hopper")
      expect(apply("Grace Hopper")).to include(target)
    end

    it "matches on github_handle via User.search" do
      target = Factories.user(github_handle: "flaky-deploy-fixer")
      expect(apply("flaky-deploy-fixer")).to include(target)
    end

    it "returns no matches for an unrelated query" do
      Factories.user(name: "Unrelated Name")
      expect(apply("nonexistent-term-xyz")).to be_empty
    end

    it "raises for an unsupported operator" do
      Factories.user
      expect { apply("anything", op: :equals) }.to raise_error(ArgumentError)
    end
  end

  describe "chip metadata" do
    it "registers as search in the admin_user subject and is pinned as the free-text search field" do
      schema = Filters::Schema.for(subject: :admin_user, user: user)
      chip = schema.find { |c| c["field"] == "search" }

      expect(chip).not_to be_nil
      expect(chip["label"]).to eq("Search")
      expect(chip["bucket"]).to eq("string")
      expect(chip["operators"]).to contain_exactly("contains")
      expect(chip["free_text_search"]).to be true
    end
  end
end
