require "rails_helper"

RSpec.describe TargetGraph::Target do
  let(:label) { TargetGraph::Label.parse("//cli:grade/tests") }

  describe "#initialize" do
    it "defaults to kind default with empty metadata" do
      target = described_class.new(label: label)
      expect(target.kind).to eq("default")
      expect(target.source_paths).to eq([])
      expect(target.command).to be_nil
      expect(target.dependencies).to eq([])
      expect(target.phases).to eq([])
      expect(target.required?).to be(false)
      expect(target.timeout_minutes).to be_nil
      expect(target.owner_config_path).to be_nil
    end

    it "coerces a raw label string" do
      target = described_class.new(label: "//cli:grade/tests")
      expect(target.label).to eq(label)
    end

    it "represents kind, source scope, command metadata, dependency labels, phase metadata, requiredness, timeout, and owner path" do
      target = described_class.new(
        label: label,
        kind: "grader",
        source_paths: [ "cli/**/*.go" ],
        command: "go test ./...",
        dependencies: [ "//cli:prepare/deps", TargetGraph::Label.parse("//cli:default") ],
        phases: %w[review landing],
        required: true,
        timeout_minutes: "15",
        owner_config_path: "cli/.syrus.yml"
      )

      expect(target.kind).to eq("grader")
      expect(target.grader?).to be(true)
      expect(target.default?).to be(false)
      expect(target.source_paths).to eq([ "cli/**/*.go" ])
      expect(target.command).to eq("go test ./...")
      expect(target.dependencies).to eq([
        TargetGraph::Label.parse("//cli:prepare/deps"),
        TargetGraph::Label.parse("//cli:default")
      ])
      expect(target.phases).to eq(%w[review landing])
      expect(target.required?).to be(true)
      expect(target.timeout_minutes).to eq(15)
      expect(target.owner_config_path).to eq("cli/.syrus.yml")
    end

    it "strips blank source paths, phases, and owner path" do
      target = described_class.new(label: label, source_paths: [ "", "  cli/**/*.go  " ], phases: [ "", "review" ], owner_config_path: "  ")
      expect(target.source_paths).to eq([ "cli/**/*.go" ])
      expect(target.phases).to eq([ "review" ])
      expect(target.owner_config_path).to be_nil
    end

    TargetGraph::Target::KINDS.each do |kind|
      it "accepts the #{kind} kind" do
        target = described_class.new(label: label, kind: kind)
        expect(target.public_send(:"#{kind}?")).to be(true)
      end
    end

    it "raises for an unknown kind" do
      expect { described_class.new(label: label, kind: "made_up") }.to raise_error(described_class::InvalidTargetError, /unknown target kind/)
    end

    it "is immutable" do
      target = described_class.new(label: label)
      expect(target).to be_frozen
    end
  end

  describe "#depends_on?" do
    it "matches a dependency by Label or raw string" do
      target = described_class.new(label: label, dependencies: [ "//cli:default" ])
      expect(target.depends_on?("//cli:default")).to be(true)
      expect(target.depends_on?(TargetGraph::Label.parse("//cli:default"))).to be(true)
      expect(target.depends_on?("//cli:prepare/deps")).to be(false)
    end
  end
end
