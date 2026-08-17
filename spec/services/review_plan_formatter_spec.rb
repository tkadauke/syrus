require "rails_helper"

RSpec.describe ReviewPlanFormatter do
  describe "#format" do
    it "returns nil when there are no items" do
      formatter = described_class.new({ "items" => [] })

      expect(formatter.format).to be_nil
    end

    it "returns nil when items is missing entirely" do
      formatter = described_class.new({})

      expect(formatter.format).to be_nil
    end

    it "includes the marker, a heading, and each item with file:line" do
      artifact = {
        "items" => [
          { "file" => "app/models/user.rb", "line" => 10, "note" => "Tricky retry logic." },
          { "file" => "app/services/foo.rb", "line" => nil, "note" => "No test coverage for the empty-input case." }
        ],
        "summary" => nil
      }

      output = described_class.new(artifact).format

      expect(output).to include(described_class::MARKER)
      expect(output).to include("## Self-Review Notes")
      expect(output).to include("`app/models/user.rb:10` — Tricky retry logic.")
      expect(output).to include("`app/services/foo.rb` — No test coverage for the empty-input case.")
    end

    it "includes the summary when present" do
      artifact = {
        "items" => [ { "file" => "app.rb", "line" => 1, "note" => "Check this." } ],
        "summary" => "Overall this change looks solid."
      }

      output = described_class.new(artifact).format

      expect(output).to include("Overall this change looks solid.")
    end
  end
end
