require "rails_helper"

RSpec.describe TargetGraph::Project do
  describe "#initialize" do
    it "synthesizes an implicit default target matching the project's own label" do
      project = described_class.new(id: "cli", label: "//cli:default", path_scope: "cli")

      expect(project.targets.map(&:label)).to eq([ TargetGraph::Label.parse("//cli:default") ])
      expect(project.default_target.kind).to eq("default")
    end

    it "does not synthesize a second default target when one is given explicitly" do
      explicit_default = TargetGraph::Target.new(label: "//cli:default", kind: "default", owner_config_path: "cli/.syrus.yml")
      project = described_class.new(id: "cli", label: "//cli:default", path_scope: "cli", targets: [ explicit_default ])

      expect(project.targets.size).to eq(1)
      expect(project.default_target).to be(explicit_default)
    end

    it "adds additional targets scoped to the same project path" do
      grader = TargetGraph::Target.new(label: "//cli:grade/tests", kind: "grader")
      project = described_class.new(id: "cli", label: "//cli:default", path_scope: "cli", targets: [ grader ])

      expect(project.target("//cli:grade/tests")).to be(grader)
      expect(project.targets.map(&:label)).to contain_exactly(
        TargetGraph::Label.parse("//cli:default"),
        TargetGraph::Label.parse("//cli:grade/tests")
      )
    end

    it "raises when a target belongs to a different project path" do
      outsider = TargetGraph::Target.new(label: "//desktop:build/package", kind: "builder")

      expect {
        described_class.new(id: "cli", label: "//cli:default", path_scope: "cli", targets: [ outsider ])
      }.to raise_error(described_class::InvalidProjectError, /does not belong to project/)
    end

    it "raises for a duplicate target label" do
      grader = TargetGraph::Target.new(label: "//cli:grade/tests", kind: "grader")
      duplicate = TargetGraph::Target.new(label: "//cli:grade/tests", kind: "grader")

      expect {
        described_class.new(id: "cli", label: "//cli:default", path_scope: "cli", targets: [ grader, duplicate ])
      }.to raise_error(described_class::InvalidProjectError, /duplicate target label/)
    end

    it "raises for a blank id" do
      expect { described_class.new(id: "  ", label: "//cli:default") }.to raise_error(described_class::InvalidProjectError, /blank/)
    end

    it "is immutable" do
      expect(described_class.new(id: "cli", label: "//cli:default")).to be_frozen
    end
  end

  describe "#target" do
    it "returns nil for a label the project doesn't own" do
      project = described_class.new(id: "cli", label: "//cli:default")
      expect(project.target("//cli:grade/tests")).to be_nil
    end
  end
end
