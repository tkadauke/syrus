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
        expect(results.length).to eq(1)
      end

      it "keeps the FilterUsage-sourced candidate (higher score wins)" do
        result = call(query: "Onboarding").first
        expect(result[:source]).to eq("frequent")
        expect(result[:label]).to eq("Epic is EPIC-1 Syrus Onboarding")
      end
    end
  end
end
