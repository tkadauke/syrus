require "rails_helper"

RSpec.describe GithubSource::IssuesFilter do
  def encoded(tree)
    Base64.urlsafe_encode64(JSON.generate(tree), padding: false)
  end

  describe ".schema" do
    it "exposes the repository issue FilterBar fields" do
      fields = described_class.schema.index_by { |field| field.fetch("field") }

      expect(fields.keys).to eq(%w[query author label delegated state])
      expect(fields.fetch("query")).to include("free_text_search" => true, "bucket" => "string", "operators" => [ "contains" ])
      expect(fields.fetch("author")).to include("bucket" => "string", "operators" => [ "contains", "is" ])
      expect(fields.fetch("label")).to include("bucket" => "string", "operators" => [ "contains", "is" ])
      expect(fields.fetch("delegated")).to include("bucket" => "enum", "operators" => [ "is" ])
      expect(fields.fetch("state")).to include("bucket" => "enum", "operators" => [ "is" ])
    end
  end

  describe "value extraction" do
    it "is nil with no filter" do
      filter = described_class.from_params(ActionController::Parameters.new)
      expect(filter.query).to be_nil
      expect(filter.author).to be_nil
      expect(filter.label).to be_nil
      expect(filter.delegated).to be_nil
      expect(filter.state).to be_nil
    end

    it "extracts supported chip values from the decoded tree" do
      tree = {
        "and" => [
          { "field" => "query", "op" => "contains", "value" => "forum" },
          { "field" => "author", "op" => "contains", "value" => "ada" },
          { "field" => "label", "op" => "is", "value" => "bug" },
          { "field" => "delegated", "op" => "is", "value" => "true" },
          { "field" => "state", "op" => "is", "value" => "open" }
        ]
      }
      filter = described_class.from_params(ActionController::Parameters.new(q: encoded(tree)))

      expect(filter.query).to eq("forum")
      expect(filter.author).to eq("ada")
      expect(filter.label).to eq("bug")
      expect(filter.delegated).to be(true)
      expect(filter.state).to eq("open")
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
