require "rails_helper"

RSpec.describe Timeline::MacroQueryFilter do
  def encode(tree) = Filters::QueryParam.encode(tree)

  describe ".schema" do
    it "describes repository_id/epic_id/hostname as fk fields, status as a multi-select enum, and window as a date bucket" do
      fields = described_class.schema.index_by { |field| field.fetch("field") }

      expect(fields.keys).to contain_exactly("repository_id", "epic_id", "hostname", "status", "window")
      expect(fields.fetch("repository_id")).to include("bucket" => "fk", "operators" => %w[ is ], "typeahead" => true)
      expect(fields.fetch("epic_id")).to include("bucket" => "fk", "operators" => %w[ is ], "typeahead" => true)
      expect(fields.fetch("hostname")).to include("bucket" => "fk", "operators" => %w[ is ], "typeahead" => true)
      expect(fields.fetch("status")).to include("bucket" => "enum", "operators" => %w[ is_one_of ])
      expect(fields.fetch("status").fetch("values")).to eq(
        [
          { "value" => "queued", "label" => "Queued" },
          { "value" => "running", "label" => "Running" },
          { "value" => "succeeded", "label" => "Succeeded" },
          { "value" => "failed", "label" => "Failed" },
          { "value" => "cancelled", "label" => "Cancelled" }
        ]
      )
      expect(fields.fetch("window")).to include("bucket" => "date", "operators" => %w[ within_last between ])
    end
  end

  describe "#from / #to" do
    it "defaults to the last 3 hours with no window chip" do
      filter = described_class.new(nil)

      expect(filter.to - filter.from).to be_within(1).of(3.hours)
    end

    it "computes an absolute range from a within_last chip" do
      filter = described_class.new({ "and" => [ { "field" => "window", "op" => "within_last", "value" => { "n" => 30, "unit" => "minutes" } } ] })

      expect(filter.to - filter.from).to be_within(1).of(30.minutes)
    end

    it "computes an absolute range from a between chip" do
      filter = described_class.new({ "and" => [ { "field" => "window", "op" => "between", "value" => [ "2026-01-01", "2026-01-02" ] } ] })

      expect(filter.from).to eq(Time.zone.parse("2026-01-01"))
      expect(filter.to).to eq(Time.zone.parse("2026-01-02"))
    end

    it "falls back to the 3-hour default (not MacroQuery's own 1-hour default) when a within_last chip has a malformed unit" do
      filter = described_class.new({ "and" => [ { "field" => "window", "op" => "within_last", "value" => { "n" => 30, "unit" => "fortnights" } } ] })

      expect(filter.from).to be_within(1).of(Time.current - 3.hours)
      expect(filter.to).to be_within(1).of(Time.current)
    end

    it "falls back to the 3-hour default on the broken side of a between chip with an unparsable bound" do
      filter = described_class.new({ "and" => [ { "field" => "window", "op" => "between", "value" => [ "not-a-date", "2026-01-02" ] } ] })

      expect(filter.from).to be_within(1).of(Time.current - 3.hours)
      expect(filter.to).to eq(Time.zone.parse("2026-01-02"))
    end
  end

  describe "#repository_id / #epic_id / #hostname / #status" do
    it "reads the chip values for the request's q param" do
      tree = {
        "and" => [
          { "field" => "repository_id", "op" => "is", "value" => 7 },
          { "field" => "epic_id", "op" => "is", "value" => 9 },
          { "field" => "hostname", "op" => "is", "value" => "worker-x" },
          { "field" => "status", "op" => "is_one_of", "value" => %w[ running queued ] }
        ]
      }
      filter = described_class.from_params(ActionController::Parameters.new(q: encode(tree)))

      expect(filter.repository_id).to eq(7)
      expect(filter.epic_id).to eq(9)
      expect(filter.hostname).to eq("worker-x")
      expect(filter.status).to eq(%w[ running queued ])
    end

    it "returns nil/empty values when no chips are present" do
      filter = described_class.new(nil)

      expect(filter.repository_id).to be_nil
      expect(filter.epic_id).to be_nil
      expect(filter.hostname).to be_nil
      expect(filter.status).to eq([])
    end

    it "ignores chips nested inside an OR group or wrapped in NOT" do
      tree = {
        "and" => [
          { "or" => [ { "field" => "repository_id", "op" => "is", "value" => 1 }, { "field" => "repository_id", "op" => "is", "value" => 2 } ] },
          { "not" => { "field" => "hostname", "op" => "is", "value" => "worker-x" } }
        ]
      }
      filter = described_class.new(tree)

      expect(filter.repository_id).to be_nil
      expect(filter.hostname).to be_nil
    end
  end

  describe "#to_h" do
    it "round-trips the decoded q param's top-level chips" do
      tree = { "and" => [ { "field" => "hostname", "op" => "is", "value" => "worker-x" } ] }
      filter = described_class.from_params(ActionController::Parameters.new(q: encode(tree)))

      expect(filter.to_h).to eq(tree)
    end

    it "serializes to an empty AND when no q param is given" do
      filter = described_class.from_params(ActionController::Parameters.new)

      expect(filter.to_h).to eq({ "and" => [] })
    end
  end
end
