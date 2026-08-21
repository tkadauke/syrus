require "rails_helper"
require "tmpdir"

RSpec.describe JavaScript::EslintGraderAugmentor do
  let(:workspace_path) { Pathname.new(Dir.mktmpdir("syrus-augmentor")) }

  after { FileUtils.rm_rf(workspace_path) }

  def write_json(filename, results)
    dir = workspace_path.join(".syrus/eslint-json")
    FileUtils.mkdir_p(dir)
    dir.join(filename).write(JSON.generate(results))
  end

  describe ".augment_grader_failure" do
    context "when the command does not contain 'eslint'" do
      it "returns nil without reading any JSON files" do
        write_json("report.json", [
          { "filePath" => "src/widget.js", "messages" => [ { "ruleId" => "no-unused-vars", "message" => "bad", "line" => 3 } ] }
        ])

        result = described_class.augment_grader_failure(
          name: "rspec", command: "bin/rspec", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end
    end

    context "when no JSON files exist in .syrus/eslint-json/" do
      it "returns nil" do
        result = described_class.augment_grader_failure(
          name: "eslint", command: "eslint --format json --output-file .syrus/eslint-json/report.json .", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end
    end

    context "when JSON files exist but contain no messages" do
      it "returns nil" do
        write_json("report.json", [
          { "filePath" => "src/widget.js", "messages" => [] }
        ])

        result = described_class.augment_grader_failure(
          name: "eslint", command: "npx eslint --format json --output-file .syrus/eslint-json/report.json .", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end
    end

    context "when JSON files contain messages" do
      it "returns a header line followed by compact file:line: message details" do
        write_json("report.json", [
          {
            "filePath" => "src/widget.js",
            "messages" => [
              { "ruleId" => "no-unused-vars", "message" => "'x' is defined but never used.", "line" => 3 }
            ]
          }
        ])

        lines = described_class.augment_grader_failure(
          name: "eslint", command: "eslint --format json --output-file .syrus/eslint-json/report.json .", workspace_path: workspace_path
        )

        expect(lines).to include("[eslint messages from JSON output]\n")
        expect(lines).to include("src/widget.js:3: no-unused-vars: 'x' is defined but never used.\n")
      end

      it "includes messages from multiple files in one report" do
        write_json("report.json", [
          { "filePath" => "a.js", "messages" => [ { "ruleId" => "rule-a", "message" => "A bad", "line" => 1 } ] },
          { "filePath" => "b.js", "messages" => [ { "ruleId" => "rule-b", "message" => "B bad", "line" => 2 } ] }
        ])

        lines = described_class.augment_grader_failure(
          name: "eslint", command: "eslint --format json --output-file .syrus/eslint-json/report.json .", workspace_path: workspace_path
        )

        expect(lines).to include("a.js:1: rule-a: A bad\n")
        expect(lines).to include("b.js:2: rule-b: B bad\n")
      end

      it "includes messages from multiple JSON report files" do
        write_json("worker-0.json", [
          { "filePath" => "a.js", "messages" => [ { "ruleId" => "rule-a", "message" => "A bad", "line" => 1 } ] }
        ])
        write_json("worker-1.json", [
          { "filePath" => "b.js", "messages" => [ { "ruleId" => "rule-b", "message" => "B bad", "line" => 2 } ] }
        ])

        lines = described_class.augment_grader_failure(
          name: "eslint", command: "eslint --format json --output-file .syrus/eslint-json/report.json .", workspace_path: workspace_path
        )

        expect(lines).to include("a.js:1: rule-a: A bad\n")
        expect(lines).to include("b.js:2: rule-b: B bad\n")
      end

      it "emits exactly one header line even across multiple files with messages" do
        write_json("report.json", [
          { "filePath" => "a.js", "messages" => [ { "ruleId" => "rule-a", "message" => "A bad", "line" => 1 } ] },
          { "filePath" => "b.js", "messages" => [ { "ruleId" => "rule-b", "message" => "B bad", "line" => 2 } ] }
        ])

        lines = described_class.augment_grader_failure(
          name: "eslint", command: "eslint --format json --output-file .syrus/eslint-json/report.json .", workspace_path: workspace_path
        )

        expect(lines.count { |l| l.include?("[eslint messages from JSON output]") }).to eq(1)
      end

      it "falls back to unknown-rule when ruleId is missing" do
        write_json("report.json", [
          { "filePath" => "a.js", "messages" => [ { "message" => "parsing error", "line" => 5 } ] }
        ])

        lines = described_class.augment_grader_failure(
          name: "eslint", command: "eslint --format json --output-file .syrus/eslint-json/report.json .", workspace_path: workspace_path
        )

        expect(lines).to include("a.js:5: unknown-rule: parsing error\n")
      end

      it "skips files that have no messages while including files that do" do
        write_json("report.json", [
          { "filePath" => "clean.js", "messages" => [] },
          { "filePath" => "dirty.js", "messages" => [ { "ruleId" => "rule-x", "message" => "bad", "line" => 1 } ] }
        ])

        lines = described_class.augment_grader_failure(
          name: "eslint", command: "eslint --format json --output-file .syrus/eslint-json/report.json .", workspace_path: workspace_path
        )

        expect(lines.join).not_to include("clean.js")
        expect(lines.join).to include("dirty.js")
      end
    end

    context "when a JSON file is malformed" do
      it "skips the bad file and returns nil when no other messages exist" do
        dir = workspace_path.join(".syrus/eslint-json")
        FileUtils.mkdir_p(dir)
        dir.join("corrupt.json").write("[ incomplete json")

        result = described_class.augment_grader_failure(
          name: "eslint", command: "eslint --format json --output-file .syrus/eslint-json/report.json .", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end

      it "still returns messages from valid files when another file is corrupt" do
        write_json("report.json", [
          { "filePath" => "a.js", "messages" => [ { "ruleId" => "rule-a", "message" => "real message", "line" => 1 } ] }
        ])
        dir = workspace_path.join(".syrus/eslint-json")
        dir.join("corrupt.json").write("[ incomplete")

        lines = described_class.augment_grader_failure(
          name: "eslint", command: "eslint --format json --output-file .syrus/eslint-json/report.json .", workspace_path: workspace_path
        )

        expect(lines).to include("a.js:1: rule-a: real message\n")
      end
    end

    it "detects eslint commands that embed eslint inside a longer shell command" do
      write_json("report.json", [
        { "filePath" => "a.js", "messages" => [ { "ruleId" => "rule-a", "message" => "bad", "line" => 1 } ] }
      ])

      lines = described_class.augment_grader_failure(
        name: "lint",
        command: "npx eslint --format json --output-file .syrus/eslint-json/report.json . --max-warnings 0",
        workspace_path: workspace_path
      )

      expect(lines).not_to be_nil
    end
  end
end
