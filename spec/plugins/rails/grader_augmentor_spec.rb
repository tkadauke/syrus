require "rails_helper"
require "tmpdir"

RSpec.describe SyrusRails::GraderAugmentor do
  let(:workspace_path) { Pathname.new(Dir.mktmpdir("syrus-augmentor")) }

  after { FileUtils.rm_rf(workspace_path) }

  def write_json(filename, examples)
    dir = workspace_path.join(".syrus/rspec-json")
    FileUtils.mkdir_p(dir)
    dir.join(filename).write(JSON.generate({ "examples" => examples }))
  end

  describe ".augment_grader_failure" do
    context "when the command does not contain 'rspec'" do
      it "returns nil without reading any JSON files" do
        write_json("worker-0.json", [{ "status" => "failed", "full_description" => "A failing test" }])

        result = described_class.augment_grader_failure(
          name: "rubocop", command: "rubocop --parallel", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end
    end

    context "when no JSON files exist in .syrus/rspec-json/" do
      it "returns nil" do
        result = described_class.augment_grader_failure(
          name: "rspec", command: "bin/rspec", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end
    end

    context "when JSON files exist but contain no failures" do
      it "returns nil" do
        write_json("worker-0.json", [
          { "status" => "passed", "full_description" => "Widget does something" }
        ])

        result = described_class.augment_grader_failure(
          name: "rspec", command: "bin/rspec", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end
    end

    context "when JSON files contain failures" do
      it "returns a header line followed by failure details" do
        write_json("worker-0.json", [
          {
            "status" => "failed",
            "full_description" => "Widget#price returns the base price",
            "exception" => { "message" => "expected: 10\n     got: 0" },
            "location" => "./spec/models/widget_spec.rb:8"
          }
        ])

        lines = described_class.augment_grader_failure(
          name: "rspec", command: "bin/rspec", workspace_path: workspace_path
        )

        expect(lines).to include("[rspec failures from JSON output]\n")
        expect(lines).to include("Widget#price returns the base price\n")
        expect(lines).to include("  expected: 10\n     got: 0\n")
        expect(lines).to include("  ./spec/models/widget_spec.rb:8\n")
      end

      it "includes failures from multiple JSON worker files" do
        write_json("worker-0.json", [
          { "status" => "failed", "full_description" => "A fails" }
        ])
        write_json("worker-1.json", [
          { "status" => "failed", "full_description" => "B fails" }
        ])

        lines = described_class.augment_grader_failure(
          name: "rspec", command: "bin/rspec", workspace_path: workspace_path
        )

        descriptions = lines.grep_v(/^\[rspec/).grep_v(/^  /)
        expect(descriptions).to include("A fails\n")
        expect(descriptions).to include("B fails\n")
      end

      it "emits exactly one header line even across multiple files with failures" do
        write_json("worker-0.json", [{ "status" => "failed", "full_description" => "X" }])
        write_json("worker-1.json", [{ "status" => "failed", "full_description" => "Y" }])

        lines = described_class.augment_grader_failure(
          name: "rspec", command: "bin/rspec", workspace_path: workspace_path
        )

        expect(lines.count { |l| l.include?("[rspec failures from JSON output]") }).to eq(1)
      end

      it "omits the exception message line when not present" do
        write_json("worker-0.json", [
          { "status" => "failed", "full_description" => "Widget pending", "location" => "./spec/widget_spec.rb:4" }
        ])

        lines = described_class.augment_grader_failure(
          name: "rspec", command: "bin/rspec", workspace_path: workspace_path
        )

        expect(lines).not_to include(match(/^  \z/))
        expect(lines).to include("  ./spec/widget_spec.rb:4\n")
      end

      it "omits the location line when not present" do
        write_json("worker-0.json", [
          {
            "status" => "failed",
            "full_description" => "Something broke",
            "exception" => { "message" => "boom" }
          }
        ])

        lines = described_class.augment_grader_failure(
          name: "rspec", command: "bin/rspec", workspace_path: workspace_path
        )

        expect(lines.join).not_to include("./spec/")
        expect(lines).to include("  boom\n")
      end

      it "skips files that mix passing and failing examples" do
        write_json("worker-0.json", [
          { "status" => "passed", "full_description" => "passes" },
          { "status" => "failed", "full_description" => "fails", "location" => "./spec/x_spec.rb:1" }
        ])

        lines = described_class.augment_grader_failure(
          name: "rspec", command: "bin/rspec", workspace_path: workspace_path
        )

        expect(lines).to include("fails\n")
        expect(lines.join).not_to include("passes")
      end
    end

    context "when a JSON file is malformed" do
      it "skips the bad file and returns nil when no other failures exist" do
        dir = workspace_path.join(".syrus/rspec-json")
        FileUtils.mkdir_p(dir)
        dir.join("corrupt.json").write("{ incomplete json")

        result = described_class.augment_grader_failure(
          name: "rspec", command: "bin/rspec", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end

      it "still returns failures from valid files when another file is corrupt" do
        write_json("worker-0.json", [
          { "status" => "failed", "full_description" => "real failure" }
        ])
        dir = workspace_path.join(".syrus/rspec-json")
        dir.join("corrupt.json").write("{ incomplete")

        lines = described_class.augment_grader_failure(
          name: "rspec", command: "bin/rspec", workspace_path: workspace_path
        )

        expect(lines).to include("real failure\n")
      end
    end

    it "detects rspec commands that embed rspec inside a longer shell command" do
      write_json("worker-0.json", [{ "status" => "failed", "full_description" => "fail" }])

      lines = described_class.augment_grader_failure(
        name: "tests",
        command: "bundle exec rspec spec/ --format progress",
        workspace_path: workspace_path
      )

      expect(lines).not_to be_nil
    end
  end
end
