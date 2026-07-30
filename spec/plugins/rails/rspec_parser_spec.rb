require "rails_helper"
require "tempfile"

RSpec.describe SyrusRails::RspecParser do
  let(:fixtures_path) { Rails.root.join("spec/fixtures/rspec") }

  def fixture(name)
    fixtures_path.join(name)
  end

  describe ".can_parse?" do
    it "returns true when format_hint is 'rspec'" do
      path = fixture("passing_output.txt")
      expect(described_class.can_parse?(output_path: path, format_hint: "rspec")).to be true
    end

    it "returns true when content looks like RSpec output (has examples + failure keywords)" do
      path = fixture("progress_output.txt")
      expect(described_class.can_parse?(output_path: path)).to be true
    end

    it "returns true for all-passing RSpec output" do
      path = fixture("passing_output.txt")
      expect(described_class.can_parse?(output_path: path)).to be true
    end

    it "returns false for non-existent files" do
      expect(described_class.can_parse?(output_path: "/nonexistent/file.txt")).to be false
    end

    it "returns false for unrelated content" do
      Tempfile.create("other") do |f|
        f.write("some unrelated log output without keywords")
        f.flush
        expect(described_class.can_parse?(output_path: f.path)).to be false
      end
    end
  end

  describe ".call" do
    context "with progress format output containing one failure" do
      let(:result) { described_class.call(output_path: fixture("progress_output.txt")) }

      it "sets status to 'failed'" do
        expect(result["status"]).to eq("failed")
      end

      it "parses the duration" do
        expect(result["duration"]).to eq(0.42)
      end

      it "parses summary counts correctly" do
        expect(result["summary"]["total"]).to eq(8)
        expect(result["summary"]["failed"]).to eq(1)
        expect(result["summary"]["pending"]).to eq(1)
        expect(result["summary"]["passed"]).to eq(6)
      end

      it "includes a TestCase for the failure" do
        expect(result["test_cases"].size).to eq(1)
      end

      it "captures the test case name" do
        tc = result["test_cases"].first
        expect(tc["name"]).to eq("GreetingHelper#greet returns the user's name")
      end

      it "captures the test case status as 'failed'" do
        tc = result["test_cases"].first
        expect(tc["status"]).to eq("failed")
      end

      it "captures the file path and line number from the location comment" do
        tc = result["test_cases"].first
        expect(tc["file_path"]).to eq("spec/helpers/greeting_helper_spec.rb")
        expect(tc["line_number"]).to eq(14)
      end

      it "captures the failure message" do
        tc = result["test_cases"].first
        expect(tc["failure_message"]).to include("expected: \"Hello, Ada\"")
      end
    end

    context "with all-passing output" do
      let(:result) { described_class.call(output_path: fixture("passing_output.txt")) }

      it "sets status to 'passed'" do
        expect(result["status"]).to eq("passed")
      end

      it "returns no test cases (no failures to enumerate)" do
        expect(result["test_cases"]).to be_empty
      end

      it "parses summary counts" do
        expect(result["summary"]["total"]).to eq(6)
        expect(result["summary"]["failed"]).to eq(0)
        expect(result["summary"]["pending"]).to eq(0)
        expect(result["summary"]["passed"]).to eq(6)
      end
    end

    context "with multiple failures" do
      let(:result) { described_class.call(output_path: fixture("multiple_failures_output.txt")) }

      it "sets status to 'failed'" do
        expect(result["status"]).to eq("failed")
      end

      it "enumerates all failing test cases" do
        expect(result["test_cases"].size).to eq(2)
      end

      it "captures distinct names for each failure" do
        names = result["test_cases"].map { |tc| tc["name"] }
        expect(names).to include("Widget#price returns the base price")
        expect(names).to include("Widget#price applies the discount")
      end

      it "captures distinct locations for each failure" do
        line_numbers = result["test_cases"].map { |tc| tc["line_number"] }
        expect(line_numbers).to contain_exactly(8, 15)
      end
    end
  end
end
