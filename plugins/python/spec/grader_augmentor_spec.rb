require "rails_helper"
require "tmpdir"

RSpec.describe Python::GraderAugmentor do
  let(:workspace_path) { Pathname.new(Dir.mktmpdir("syrus-python-augmentor")) }

  after { FileUtils.rm_rf(workspace_path) }

  def write_json(filename, tests)
    dir = workspace_path.join(".syrus/pytest-json")
    FileUtils.mkdir_p(dir)
    dir.join(filename).write(JSON.generate({ "tests" => tests }))
  end

  describe ".augment_grader_failure" do
    context "when the command does not contain 'pytest'" do
      it "returns nil without reading any JSON files" do
        write_json("report.json", [{ "outcome" => "failed", "nodeid" => "test_x.py::test_a" }])

        result = described_class.augment_grader_failure(
          name: "eslint", command: "eslint .", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end
    end

    context "when no JSON files exist in .syrus/pytest-json/" do
      it "returns nil" do
        result = described_class.augment_grader_failure(
          name: "pytest", command: "pytest", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end
    end

    context "when JSON files exist but contain no failures" do
      it "returns nil" do
        write_json("report.json", [
          { "outcome" => "passed", "nodeid" => "test_x.py::test_a" }
        ])

        result = described_class.augment_grader_failure(
          name: "pytest", command: "pytest", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end
    end

    context "when JSON files contain failures" do
      it "returns a header line followed by compact failure details from crash.message" do
        write_json("report.json", [
          {
            "outcome" => "failed",
            "nodeid" => "test_widget.py::test_price_is_base_price",
            "call" => {
              "outcome" => "failed",
              "crash" => { "path" => "test_widget.py", "lineno" => 8, "message" => "assert 0 == 10" },
              "longrepr" => "def test_price_is_base_price():\n>       assert 0 == 10\nE       assert 0 == 10"
            }
          }
        ])

        lines = described_class.augment_grader_failure(
          name: "pytest", command: "pytest --json-report", workspace_path: workspace_path
        )

        expect(lines).to include("[pytest failures from JSON report]\n")
        expect(lines).to include("FAILED: test_widget.py::test_price_is_base_price — assert 0 == 10\n")
      end

      it "falls back to the first line of call.longrepr when crash.message is absent" do
        write_json("report.json", [
          {
            "outcome" => "failed",
            "nodeid" => "test_widget.py::test_something",
            "call" => { "longrepr" => "AssertionError: boom\nmore detail on the next line" }
          }
        ])

        lines = described_class.augment_grader_failure(
          name: "pytest", command: "pytest --json-report", workspace_path: workspace_path
        )

        expect(lines).to include("FAILED: test_widget.py::test_something — AssertionError: boom\n")
      end

      it "omits the em-dash message segment when no message is available" do
        write_json("report.json", [
          { "outcome" => "failed", "nodeid" => "test_widget.py::test_bare" }
        ])

        lines = described_class.augment_grader_failure(
          name: "pytest", command: "pytest --json-report", workspace_path: workspace_path
        )

        expect(lines).to include("FAILED: test_widget.py::test_bare\n")
      end

      it "includes error outcomes as well as failed outcomes" do
        write_json("report.json", [
          { "outcome" => "error", "nodeid" => "test_widget.py::test_setup_blew_up" }
        ])

        lines = described_class.augment_grader_failure(
          name: "pytest", command: "pytest --json-report", workspace_path: workspace_path
        )

        expect(lines).to include("FAILED: test_widget.py::test_setup_blew_up\n")
      end

      it "includes failures from multiple JSON report files" do
        write_json("report-a.json", [{ "outcome" => "failed", "nodeid" => "a.py::test_a" }])
        write_json("report-b.json", [{ "outcome" => "failed", "nodeid" => "b.py::test_b" }])

        lines = described_class.augment_grader_failure(
          name: "pytest", command: "pytest --json-report", workspace_path: workspace_path
        )

        joined = lines.join
        expect(joined).to include("a.py::test_a")
        expect(joined).to include("b.py::test_b")
      end

      it "emits exactly one header line even across multiple files with failures" do
        write_json("report-a.json", [{ "outcome" => "failed", "nodeid" => "a.py::test_a" }])
        write_json("report-b.json", [{ "outcome" => "failed", "nodeid" => "b.py::test_b" }])

        lines = described_class.augment_grader_failure(
          name: "pytest", command: "pytest --json-report", workspace_path: workspace_path
        )

        expect(lines.count { |l| l.include?("[pytest failures from JSON report]") }).to eq(1)
      end

      it "skips files that mix passing and failing tests" do
        write_json("report.json", [
          { "outcome" => "passed", "nodeid" => "a.py::test_passes" },
          { "outcome" => "failed", "nodeid" => "a.py::test_fails" }
        ])

        lines = described_class.augment_grader_failure(
          name: "pytest", command: "pytest --json-report", workspace_path: workspace_path
        )

        joined = lines.join
        expect(joined).to include("test_fails")
        expect(joined).not_to include("test_passes")
      end
    end

    context "when a JSON file is malformed" do
      it "skips the bad file and returns nil when no other failures exist" do
        dir = workspace_path.join(".syrus/pytest-json")
        FileUtils.mkdir_p(dir)
        dir.join("corrupt.json").write("{ incomplete json")

        result = described_class.augment_grader_failure(
          name: "pytest", command: "pytest --json-report", workspace_path: workspace_path
        )

        expect(result).to be_nil
      end

      it "still returns failures from valid files when another file is corrupt" do
        write_json("report.json", [{ "outcome" => "failed", "nodeid" => "a.py::test_real" }])
        dir = workspace_path.join(".syrus/pytest-json")
        dir.join("corrupt.json").write("{ incomplete")

        lines = described_class.augment_grader_failure(
          name: "pytest", command: "pytest --json-report", workspace_path: workspace_path
        )

        expect(lines.join).to include("test_real")
      end
    end

    it "detects pytest commands that embed pytest inside a longer shell command" do
      write_json("report.json", [{ "outcome" => "failed", "nodeid" => "a.py::test_fails" }])

      lines = described_class.augment_grader_failure(
        name: "tests",
        command: "bundle exec true && pytest --json-report --json-report-file=.syrus/pytest-json/report.json",
        workspace_path: workspace_path
      )

      expect(lines).not_to be_nil
    end
  end
end
