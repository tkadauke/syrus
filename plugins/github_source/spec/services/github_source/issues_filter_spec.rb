require "rails_helper"

RSpec.describe GithubSource::IssuesFilter do
  def encoded(tree)
    Base64.urlsafe_encode64(JSON.generate(tree), padding: false)
  end

  describe ".schema" do
    it "exposes a single free-text query field" do
      fields = described_class.schema.index_by { |field| field.fetch("field") }

      expect(fields.keys).to eq([ "query" ])
      expect(fields.fetch("query")).to include("free_text_search" => true, "bucket" => "string", "operators" => [ "contains" ])
    end
  end

  describe "#query" do
    it "is nil with no filter" do
      filter = described_class.from_params(ActionController::Parameters.new)
      expect(filter.query).to be_nil
    end

    it "extracts the query chip's value from the decoded tree" do
      tree = { "and" => [ { "field" => "query", "op" => "contains", "value" => "forum" } ] }
      filter = described_class.from_params(ActionController::Parameters.new(q: encoded(tree)))

      expect(filter.query).to eq("forum")
    end

    it "ignores chips for fields it doesn't own" do
      tree = { "and" => [ { "field" => "unrelated", "op" => "is", "value" => "x" } ] }
      filter = described_class.from_params(ActionController::Parameters.new(q: encoded(tree)))

      expect(filter.query).to be_nil
    end
  end

  describe "#to_h" do
    it "round-trips the decoded tree" do
      tree = { "and" => [ { "field" => "query", "op" => "contains", "value" => "forum" } ] }
      filter = described_class.from_params(ActionController::Parameters.new(q: encoded(tree)))

      expect(filter.to_h).to eq(tree)
    end

    it "serializes an empty AND tree when no filter is present" do
      filter = described_class.from_params(ActionController::Parameters.new)

      expect(filter.to_h).to eq({ "and" => [] })
    end
  end
end
