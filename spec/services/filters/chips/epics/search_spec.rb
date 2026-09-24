require "rails_helper"

RSpec.describe Filters::Chips::Epics::Search do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def apply(value, op: :contains)
    described_class.new(scope: Epic.where(repository: repository), op: op, value: value, user: user).apply
  end

  describe "#apply" do
    it "matches on title via Epic.search" do
      epic = Factories.epic(user: user, repository: repository, title: "Fix the flaky deploy spec")
      expect(apply("flaky deploy")).to include(epic)
    end

    it "matches on description via Epic.search" do
      epic = Factories.epic(user: user, repository: repository, title: "Unrelated title", description: "The Kubernetes worker pods keep restarting.")
      expect(apply("Kubernetes worker")).to include(epic)
    end

    it "returns no matches for an unrelated query" do
      Factories.epic(user: user, repository: repository, title: "Unrelated title")
      expect(apply("nonexistent-term-xyz")).to be_empty
    end

    it "uses the adapter-quoted LIKE escape literal" do
      allow(Epic.connection).to receive(:quote).and_call_original
      allow(Epic.connection).to receive(:quote).with("\\").and_return("'\\\\'")

      sql = apply("deploy").to_sql

      expect(sql).to include("title LIKE")
      expect(sql).to include("ESCAPE '\\\\'")
    end

    it "raises for an unsupported operator" do
      Factories.epic(user: user, repository: repository)
      expect { apply("anything", op: :equals) }.to raise_error(ArgumentError)
    end
  end

  describe "chip metadata" do
    it "registers as search in the epic subject and is pinned as the free-text search field" do
      schema = Filters::Schema.for(subject: :epic, user: user)
      chip = schema.find { |c| c["field"] == "search" }

      expect(chip).not_to be_nil
      expect(chip["label"]).to eq("Search")
      expect(chip["bucket"]).to eq("string")
      expect(chip["operators"]).to contain_exactly("contains")
      expect(chip["free_text_search"]).to be true
    end
  end
end
