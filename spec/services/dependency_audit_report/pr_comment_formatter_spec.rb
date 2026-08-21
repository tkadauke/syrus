require "rails_helper"

RSpec.describe DependencyAuditReport::PrCommentFormatter do
  describe "#format" do
    it "returns nil when there are no results" do
      formatter = described_class.new({ "results" => [] })
      expect(formatter.format).to be_nil
    end

    it "returns nil when every scanned ecosystem came back clean" do
      artifact = {
        "results" => [
          { "ecosystem" => "Ruby", "command" => "bundle-audit check --update", "exit_status" => 0, "clean" => true, "output_tail" => "No vulnerabilities found" }
        ]
      }
      formatter = described_class.new(artifact)
      expect(formatter.format).to be_nil
    end

    it "renders a marker and a details section per flagged ecosystem" do
      artifact = {
        "results" => [
          { "ecosystem" => "Ruby", "command" => "bundle-audit check --update", "exit_status" => 0, "clean" => true, "output_tail" => "clean" },
          { "ecosystem" => "JavaScript", "command" => "npm audit --json", "exit_status" => 1, "clean" => false, "output_tail" => "1 high severity vulnerability" }
        ]
      }
      formatter = described_class.new(artifact)
      body = formatter.format

      expect(body).to start_with(described_class::MARKER)
      expect(body).to include("## Dependency Vulnerability Scan")
      expect(body).to include("JavaScript")
      expect(body).to include("npm audit --json")
      expect(body).to include("1 high severity vulnerability")
      expect(body).not_to include("bundle-audit")
    end

    it "truncates long output to the last OUTPUT_LINES lines" do
      long_output = (1..100).map { |i| "line #{i}" }.join("\n")
      artifact = {
        "results" => [
          { "ecosystem" => "Go", "command" => "govulncheck ./...", "exit_status" => 1, "clean" => false, "output_tail" => long_output }
        ]
      }
      formatter = described_class.new(artifact)
      body = formatter.format

      expect(body).to include("... (truncated)")
      expect(body).to include("line 100")
      expect(body).not_to include("line 1\n")
    end
  end
end
