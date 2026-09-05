require "rails_helper"

RSpec.describe TargetGraph::Target do
  let(:label) { TargetGraph::Label.parse("//cli:grade/tests") }
  let(:prepare_label) { TargetGraph::Label.parse("//cli:prepare/deps") }

  describe "#initialize" do
    it "defaults optional attributes" do
      target = described_class.new(label: label, kind: "grader", project_id: "cli")

      expect(target.source_scope).to eq([])
      expect(target.command).to be_nil
      expect(target.dependencies).to eq([])
      expect(target.phases).to eq([])
      expect(target.required).to be(false)
      expect(target.timeout_minutes).to be_nil
      expect(target.owner_config_path).to be_nil
      expect(target).not_to be_executable
    end

    it "represents kind, source scope, command metadata, dependency labels, phase metadata, requiredness, timeout, and owner path" do
      target = described_class.new(
        label: label,
        kind: "grader",
        project_id: "cli",
        source_scope: [ "cli/**/*.go" ],
        command: "mise exec go@1.26.5 -- go test ./...",
        dependencies: [ prepare_label ],
        phases: %w[review landing ci],
        required: true,
        timeout_minutes: 15,
        owner_config_path: "cli/.syrus.yml"
      )

      expect(target.kind).to eq("grader")
      expect(target.source_scope).to eq([ "cli/**/*.go" ])
      expect(target.command).to eq("mise exec go@1.26.5 -- go test ./...")
      expect(target.dependencies).to eq([ prepare_label ])
      expect(target).to be_depends_on(prepare_label)
      expect(target.phases).to eq(%w[review landing ci])
      expect(target.required).to be(true)
      expect(target.timeout_minutes).to eq(15)
      expect(target.owner_config_path).to eq("cli/.syrus.yml")
      expect(target).to be_executable
    end

    it "rejects a non-Label label" do
      expect { described_class.new(label: "//cli:default", kind: "default", project_id: "cli") }.to raise_error(ArgumentError)
    end

    it "rejects an unknown kind" do
      expect { described_class.new(label: label, kind: "bogus", project_id: "cli") }.to raise_error(ArgumentError, /kind/)
    end

    it "rejects dependencies that are not Labels" do
      expect { described_class.new(label: label, kind: "grader", project_id: "cli", dependencies: [ "//cli:prepare/deps" ]) }
        .to raise_error(ArgumentError, /dependencies/)
    end

    it "rejects unknown phases" do
      expect { described_class.new(label: label, kind: "grader", project_id: "cli", phases: [ "nightly" ]) }
        .to raise_error(ArgumentError, /phases/)
    end

    it "rejects a non-positive timeout" do
      expect { described_class.new(label: label, kind: "grader", project_id: "cli", timeout_minutes: 0) }
        .to raise_error(ArgumentError, /timeout_minutes/)
    end

    it "rejects a blank project_id" do
      expect { described_class.new(label: label, kind: "grader", project_id: "") }.to raise_error(ArgumentError)
    end
  end
end
