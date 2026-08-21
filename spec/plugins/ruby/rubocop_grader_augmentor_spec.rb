require "rails_helper"
require "tmpdir"

RSpec.describe Ruby::RubocopGraderAugmentor do
  let(:workspace_path) { Pathname.new(Dir.mktmpdir("syrus-augmentor")) }

  after { FileUtils.rm_rf(workspace_path) }

  def write_json(filename, files)
    dir = workspace_path.join(".syrus/rubocop-json")
    FileUtils.mkdir_p(dir)
    dir.join(filename).write(JSON.generate({ "files" => files }))
  end

  describe ".augment_grader_failure" do
    context "when the command does not contain 'rubocop'" do
      it "returns nil without reading any JSON files" do
        write_json("report.json", [
          { "path" => "app/models/widget.rb", "offenses" => [ { "cop_name" => "Style/StringLiterals", "message" => "bad", "location" => { "line" => 3 } } ] }
        ])

        result = described_class.augment_grader_failure(
          name: "rspec", command: "bin/rspec", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end
    end

    context "when no JSON files exist in .syrus/rubocop-json/" do
      it "returns nil" do
        result = described_class.augment_grader_failure(
          name: "rubocop", command: "rubocop --format json --out .syrus/rubocop-json/report.json", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end
    end

    context "when JSON files exist but contain no offenses" do
      it "returns nil" do
        write_json("report.json", [
          { "path" => "app/models/widget.rb", "offenses" => [] }
        ])

        result = described_class.augment_grader_failure(
          name: "rubocop", command: "bundle exec rubocop --format json --out .syrus/rubocop-json/report.json", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end
    end

    context "when JSON files contain offenses" do
      it "returns a header line followed by compact file:line: message details" do
        write_json("report.json", [
          {
            "path" => "app/models/widget.rb",
            "offenses" => [
              {
                "cop_name" => "Style/FrozenStringLiteralComment",
                "message" => "Missing magic comment `# frozen_string_literal: true`.",
                "location" => { "line" => 1, "column" => 1 }
              }
            ]
          }
        ])

        lines = described_class.augment_grader_failure(
          name: "rubocop", command: "rubocop --format json --out .syrus/rubocop-json/report.json", workspace_path: workspace_path
        )

        expect(lines).to include("[rubocop offenses from JSON output]\n")
        expect(lines).to include(
          "app/models/widget.rb:1: Style/FrozenStringLiteralComment: Missing magic comment `# frozen_string_literal: true`.\n"
        )
      end

      it "includes offenses from multiple files in one report" do
        write_json("report.json", [
          { "path" => "a.rb", "offenses" => [ { "cop_name" => "Cop/A", "message" => "A bad", "location" => { "line" => 1 } } ] },
          { "path" => "b.rb", "offenses" => [ { "cop_name" => "Cop/B", "message" => "B bad", "location" => { "line" => 2 } } ] }
        ])

        lines = described_class.augment_grader_failure(
          name: "rubocop", command: "rubocop --format json --out .syrus/rubocop-json/report.json", workspace_path: workspace_path
        )

        expect(lines).to include("a.rb:1: Cop/A: A bad\n")
        expect(lines).to include("b.rb:2: Cop/B: B bad\n")
      end

      it "includes offenses from multiple JSON report files" do
        write_json("worker-0.json", [
          { "path" => "a.rb", "offenses" => [ { "cop_name" => "Cop/A", "message" => "A bad", "location" => { "line" => 1 } } ] }
        ])
        write_json("worker-1.json", [
          { "path" => "b.rb", "offenses" => [ { "cop_name" => "Cop/B", "message" => "B bad", "location" => { "line" => 2 } } ] }
        ])

        lines = described_class.augment_grader_failure(
          name: "rubocop", command: "rubocop --format json --out .syrus/rubocop-json/report.json", workspace_path: workspace_path
        )

        expect(lines).to include("a.rb:1: Cop/A: A bad\n")
        expect(lines).to include("b.rb:2: Cop/B: B bad\n")
      end

      it "emits exactly one header line even across multiple files with offenses" do
        write_json("report.json", [
          { "path" => "a.rb", "offenses" => [ { "cop_name" => "Cop/A", "message" => "A bad", "location" => { "line" => 1 } } ] },
          { "path" => "b.rb", "offenses" => [ { "cop_name" => "Cop/B", "message" => "B bad", "location" => { "line" => 2 } } ] }
        ])

        lines = described_class.augment_grader_failure(
          name: "rubocop", command: "rubocop --format json --out .syrus/rubocop-json/report.json", workspace_path: workspace_path
        )

        expect(lines.count { |l| l.include?("[rubocop offenses from JSON output]") }).to eq(1)
      end

      it "falls back to unknown-cop when cop_name is missing" do
        write_json("report.json", [
          { "path" => "a.rb", "offenses" => [ { "message" => "mystery offense", "location" => { "line" => 5 } } ] }
        ])

        lines = described_class.augment_grader_failure(
          name: "rubocop", command: "rubocop --format json --out .syrus/rubocop-json/report.json", workspace_path: workspace_path
        )

        expect(lines).to include("a.rb:5: unknown-cop: mystery offense\n")
      end

      it "skips files that have no offenses while including files that do" do
        write_json("report.json", [
          { "path" => "clean.rb", "offenses" => [] },
          { "path" => "dirty.rb", "offenses" => [ { "cop_name" => "Cop/X", "message" => "bad", "location" => { "line" => 1 } } ] }
        ])

        lines = described_class.augment_grader_failure(
          name: "rubocop", command: "rubocop --format json --out .syrus/rubocop-json/report.json", workspace_path: workspace_path
        )

        expect(lines.join).not_to include("clean.rb")
        expect(lines.join).to include("dirty.rb")
      end
    end

    context "when a JSON file is malformed" do
      it "skips the bad file and returns nil when no other offenses exist" do
        dir = workspace_path.join(".syrus/rubocop-json")
        FileUtils.mkdir_p(dir)
        dir.join("corrupt.json").write("{ incomplete json")

        result = described_class.augment_grader_failure(
          name: "rubocop", command: "rubocop --format json --out .syrus/rubocop-json/report.json", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end

      it "still returns offenses from valid files when another file is corrupt" do
        write_json("report.json", [
          { "path" => "a.rb", "offenses" => [ { "cop_name" => "Cop/A", "message" => "real offense", "location" => { "line" => 1 } } ] }
        ])
        dir = workspace_path.join(".syrus/rubocop-json")
        dir.join("corrupt.json").write("{ incomplete")

        lines = described_class.augment_grader_failure(
          name: "rubocop", command: "rubocop --format json --out .syrus/rubocop-json/report.json", workspace_path: workspace_path
        )

        expect(lines).to include("a.rb:1: Cop/A: real offense\n")
      end
    end

    it "detects rubocop commands that embed rubocop inside a longer shell command" do
      write_json("report.json", [
        { "path" => "a.rb", "offenses" => [ { "cop_name" => "Cop/A", "message" => "bad", "location" => { "line" => 1 } } ] }
      ])

      lines = described_class.augment_grader_failure(
        name: "lint",
        command: "bundle exec rubocop --format json --out .syrus/rubocop-json/report.json --parallel",
        workspace_path: workspace_path
      )

      expect(lines).not_to be_nil
    end
  end
end
