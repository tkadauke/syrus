require "rails_helper"

RSpec.describe TestInsights::TestsFilter do
  def encoded(tree)
    Base64.urlsafe_encode64(JSON.generate(tree), padding: false)
  end

  describe ".schema" do
    it "exposes a free-text query field and a single-select reason field" do
      fields = described_class.schema.index_by { |field| field.fetch("field") }

      expect(fields.fetch("query")).to include("free_text_search" => true, "bucket" => "string")
      expect(fields.fetch("reason")).to include("bucket" => "enum", "operators" => [ "is" ])
      expect(fields.fetch("reason").fetch("values").map { |value| value.fetch("value") }).to contain_exactly("failing", "flaky", "slow")
    end
  end

  describe "#active?" do
    it "is false with no filter" do
      filter = described_class.from_params(ActionController::Parameters.new)
      expect(filter.active?).to be(false)
    end

    it "is true once either field has a value" do
      tree = { "and" => [ { "field" => "query", "op" => "contains", "value" => "needle" } ] }
      filter = described_class.from_params(ActionController::Parameters.new(q: encoded(tree)))
      expect(filter.active?).to be(true)
    end

    it "ignores chips for fields it doesn't own" do
      tree = { "and" => [ { "field" => "unrelated", "op" => "is", "value" => "x" } ] }
      filter = described_class.from_params(ActionController::Parameters.new(q: encoded(tree)))
      expect(filter.active?).to be(false)
    end
  end

  describe "#query and #reason" do
    it "extracts both values from a combined tree" do
      tree = {
        "and" => [
          { "field" => "query", "op" => "contains", "value" => "needle" },
          { "field" => "reason", "op" => "is", "value" => "flaky" }
        ]
      }
      filter = described_class.from_params(ActionController::Parameters.new(q: encoded(tree)))

      expect(filter.query).to eq("needle")
      expect(filter.reason).to eq("flaky")
    end

    it "round-trips through #to_h" do
      tree = { "and" => [ { "field" => "reason", "op" => "is", "value" => "slow" } ] }
      filter = described_class.from_params(ActionController::Parameters.new(q: encoded(tree)))

      expect(filter.to_h).to eq(tree)
    end
  end
end
