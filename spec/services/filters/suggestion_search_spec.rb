require "rails_helper"

RSpec.describe Filters::SuggestionSearch do
  let(:user) { Factories.user }

  def call(**opts)
    described_class.call(user: user, surface: "dashboard", subject: "job", **opts)
  end

  describe "label-based deduplication" do
    # Regression: FilterUsage stores FK values from the URL q param, which can be
    # serialized as strings ("1"), while FkOptionsResolver always returns integer
    # record IDs. canonical_value does not normalize types, so fingerprint("1") !=
    # fingerprint(1). Both candidates survive fingerprint-dedup and appear twice.
    # The secondary label-based pass catches this.
    context "when FilterUsage stores a string FK value and the live resolver returns an integer" do
      before do
        FilterUsage.create!(
          user: user,
          surface: "dashboard",
          subject: "job",
          fingerprint: "fp-string-epic-1",
          filter_node: { "field" => "epic_id", "op" => "is", "value" => "1" },
          label: "Epic is EPIC-1 Syrus Onboarding",
          use_count: 5,
          last_used_at: 1.hour.ago
        )

        allow_any_instance_of(Filters::FkOptionsResolver).to receive(:resolve).and_return([])
        allow_any_instance_of(Filters::FkOptionsResolver).to receive(:resolve)
          .with(field: "epic_id", q: "Onboarding", limit: anything)
          .and_return([{ "value" => 1, "label" => "EPIC-1 Syrus Onboarding" }])
      end

      it "returns exactly one suggestion" do
        results = call(query: "Onboarding")
        expect(results.count { |result| result[:label] == "Epic is EPIC-1 Syrus Onboarding" }).to eq(1)
      end

      it "keeps the FilterUsage-sourced candidate (higher score wins)" do
        result = call(query: "Onboarding").find { |candidate| candidate[:label] == "Epic is EPIC-1 Syrus Onboarding" }
        expect(result[:source]).to eq("frequent")
        expect(result[:label]).to eq("Epic is EPIC-1 Syrus Onboarding")
      end
    end
  end

  describe "typed text-search suggestions" do
    it "synthesizes full-text suggestions for searchable text fields" do
      results = call(query: "merge train")

      expect(results).to include(
        hash_including(
          label: 'Title matches "merge train"',
          source: "text",
          filter: { "field" => "title", "op" => "matches", "value" => "merge train" }
        ),
        hash_including(
          label: 'Description matches "merge train"',
          source: "text",
          filter: { "field" => "description", "op" => "matches", "value" => "merge train" }
        )
      )
    end

    it "deduplicates synthesized text suggestions against active chips" do
      active_tree = { "and" => [ { "field" => "title", "op" => "matches", "value" => "merge train" } ] }

      labels = call(query: "merge train", active_tree: active_tree).map { |result| result.fetch(:label) }

      expect(labels).not_to include('Title matches "merge train"')
      expect(labels).to include('Description matches "merge train"')
    end

    it "deduplicates synthesized text suggestions against chips inside groups" do
      active_tree = {
        "and" => [
          {
            "or" => [
              { "field" => "state", "op" => "is", "value" => "open" },
              { "field" => "title", "op" => "matches", "value" => "merge train" }
            ]
          }
        ]
      }

      labels = call(query: "merge train", active_tree: active_tree).map { |result| result.fetch(:label) }

      expect(labels).not_to include('Title matches "merge train"')
      expect(labels).to include('Description matches "merge train"')
    end

    it "emits AST nodes that the compiler can apply" do
      result = call(query: "merge train").find { |candidate| candidate.fetch(:label) == 'Title matches "merge train"' }

      node = Filters::Ast.parse(result.fetch(:filter))

      expect(node.field).to eq("title")
      expect(node.op).to eq("matches")
      expect(node.value).to eq("merge train")
    end
  end
end
