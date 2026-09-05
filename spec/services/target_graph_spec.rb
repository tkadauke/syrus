require "rails_helper"

RSpec.describe TargetGraph do
  subject(:graph) { described_class.new }

  describe "implicit root project/target" do
    it "is present on every graph, even with no additional configuration" do
      expect(graph.root_project.id).to eq("repo")
      expect(graph.root_project).to be_root
      expect(graph.root_target.label.to_s).to eq("//:repo")
      expect(graph.root_target.kind).to eq("default")
      expect(graph.root_target.project_id).to eq("repo")
    end

    it "is queryable through #project and #target" do
      expect(graph.project("repo")).to eq(graph.root_project)
      expect(graph.target(described_class.root_label)).to eq(graph.root_target)
    end

    it "validates cleanly by itself" do
      expect(graph.validate!).to be(true)
      expect(graph.cycles).to eq([])
    end
  end

  describe "#add_project" do
    it "adds a new project" do
      project = TargetGraph::Project.new(id: "cli", path: "cli")
      graph.add_project(project)

      expect(graph.project("cli")).to eq(project)
    end

    it "rejects a duplicate project id" do
      graph.add_project(TargetGraph::Project.new(id: "cli", path: "cli"))

      expect { graph.add_project(TargetGraph::Project.new(id: "cli", path: "cli")) }
        .to raise_error(TargetGraph::ValidationError, /cli.*already declared/)
    end

    it "rejects re-declaring the implicit root project id" do
      expect { graph.add_project(TargetGraph::Project.new(id: "repo")) }
        .to raise_error(TargetGraph::ValidationError)
    end
  end

  describe "#add_target" do
    before { graph.add_project(TargetGraph::Project.new(id: "cli", path: "cli")) }

    it "adds a new target scoped to a known project" do
      label = TargetGraph::Label.parse("//cli:default")
      target = TargetGraph::Target.new(label: label, kind: "default", project_id: "cli")
      graph.add_target(target)

      expect(graph.target(label)).to eq(target)
      expect(graph.targets_for_project("cli")).to eq([ target ])
    end

    it "rejects a duplicate target label" do
      label = TargetGraph::Label.parse("//cli:default")
      graph.add_target(TargetGraph::Target.new(label: label, kind: "default", project_id: "cli"))

      expect { graph.add_target(TargetGraph::Target.new(label: label, kind: "default", project_id: "cli")) }
        .to raise_error(TargetGraph::ValidationError, /already declared/)
    end

    it "rejects a target referencing an unknown project" do
      label = TargetGraph::Label.parse("//cli:default")
      target = TargetGraph::Target.new(label: label, kind: "default", project_id: "missing")

      expect { graph.add_target(target) }.to raise_error(TargetGraph::ValidationError, /unknown project/)
    end
  end

  describe "#validate!" do
    before { graph.add_project(TargetGraph::Project.new(id: "cli", path: "cli")) }

    it "raises when a target depends on a label that was never declared" do
      default_label = TargetGraph::Label.parse("//cli:default")
      missing_dep = TargetGraph::Label.parse("//cli:prepare/deps")
      graph.add_target(TargetGraph::Target.new(label: default_label, kind: "default", project_id: "cli", dependencies: [ missing_dep ]))

      expect { graph.validate! }.to raise_error(TargetGraph::ValidationError, /unknown target/)
    end

    it "names the owning .syrus.yml path alongside the target label in a missing-dependency error" do
      default_label = TargetGraph::Label.parse("//cli:default")
      missing_dep = TargetGraph::Label.parse("//cli:prepare/deps")
      graph.add_target(
        TargetGraph::Target.new(
          label: default_label, kind: "default", project_id: "cli",
          dependencies: [ missing_dep ], owner_config_path: "cli/.syrus.yml"
        )
      )

      expect { graph.validate! }.to raise_error(TargetGraph::ValidationError) do |error|
        expect(error.message).to include("//cli:default").and include("cli/.syrus.yml").and include("//cli:prepare/deps")
      end
    end

    it "falls back to a plain 'no owning .syrus.yml' description when a target has none" do
      default_label = TargetGraph::Label.parse("//cli:default")
      missing_dep = TargetGraph::Label.parse("//cli:prepare/deps")
      graph.add_target(TargetGraph::Target.new(label: default_label, kind: "default", project_id: "cli", dependencies: [ missing_dep ]))

      expect { graph.validate! }.to raise_error(TargetGraph::ValidationError, /no owning \.syrus\.yml/)
    end

    it "passes when every dependency resolves to a declared target" do
      default_label = TargetGraph::Label.parse("//cli:default")
      grade_label = TargetGraph::Label.parse("//cli:grade/tests")
      graph.add_target(TargetGraph::Target.new(label: default_label, kind: "default", project_id: "cli"))
      graph.add_target(TargetGraph::Target.new(label: grade_label, kind: "grader", project_id: "cli", dependencies: [ default_label ], required: true))

      expect(graph.validate!).to be(true)
    end

    it "detects a direct dependency cycle" do
      a = TargetGraph::Label.parse("//cli:a")
      b = TargetGraph::Label.parse("//cli:b")
      graph.add_target(TargetGraph::Target.new(label: a, kind: "library", project_id: "cli", dependencies: [ b ]))
      graph.add_target(TargetGraph::Target.new(label: b, kind: "library", project_id: "cli", dependencies: [ a ]))

      expect { graph.validate! }.to raise_error(TargetGraph::ValidationError, /dependency cycle/)
      expect(graph.cycles).not_to be_empty
    end

    it "detects an indirect (transitive) dependency cycle" do
      a = TargetGraph::Label.parse("//cli:a")
      b = TargetGraph::Label.parse("//cli:b")
      c = TargetGraph::Label.parse("//cli:c")
      graph.add_target(TargetGraph::Target.new(label: a, kind: "library", project_id: "cli", dependencies: [ b ]))
      graph.add_target(TargetGraph::Target.new(label: b, kind: "library", project_id: "cli", dependencies: [ c ]))
      graph.add_target(TargetGraph::Target.new(label: c, kind: "library", project_id: "cli", dependencies: [ a ]))

      expect(graph.cycles).not_to be_empty
      expect { graph.validate! }.to raise_error(TargetGraph::ValidationError, /dependency cycle/)
    end

    it "collects multiple problems in one error instead of raising on the first" do
      default_label = TargetGraph::Label.parse("//cli:default")
      missing_dep = TargetGraph::Label.parse("//cli:prepare/deps")
      graph.add_target(TargetGraph::Target.new(label: default_label, kind: "default", project_id: "cli", dependencies: [ missing_dep ]))

      other_missing = TargetGraph::Label.parse("//cli:grade/tests")
      other_dep = TargetGraph::Label.parse("//cli:build/binary")
      graph.add_target(TargetGraph::Target.new(label: other_missing, kind: "grader", project_id: "cli", dependencies: [ other_dep ]))

      expect { graph.validate! }.to raise_error(TargetGraph::ValidationError) do |error|
        expect(error.message).to include("prepare/deps").and include("build/binary")
      end
    end
  end
end
