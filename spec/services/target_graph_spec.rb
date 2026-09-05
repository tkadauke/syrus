require "rails_helper"

RSpec.describe TargetGraph do
  describe "#initialize" do
    it "seeds every graph with the implicit root project and target" do
      graph = described_class.new

      expect(graph.root_project.id).to eq("repo")
      expect(graph.root_project.label.to_s).to eq("//:repo")
      expect(graph.find_target("//:repo")).not_to be_nil
      expect(graph.find_target("//:repo").kind).to eq("default")
      expect(graph.find_target("//:repo").owner_config_path).to eq(".syrus.yml")
    end

    it "accepts a custom owner config path for the implicit root" do
      graph = described_class.new(owner_config_path: "custom.syrus.yml")
      expect(graph.find_target("//:repo").owner_config_path).to eq("custom.syrus.yml")
    end
  end

  describe "#add_project" do
    it "adds a nested project and its targets to the graph" do
      graph = described_class.new
      cli_project = TargetGraph::Project.new(id: "cli", label: "//cli:default", path_scope: "cli")

      graph.add_project(cli_project)

      expect(graph.project("cli")).to be(cli_project)
      expect(graph.projects.map(&:id)).to contain_exactly("repo", "cli")
      expect(graph.find_target("//cli:default")).not_to be_nil
    end

    it "raises for a duplicate project id" do
      graph = described_class.new
      graph.add_project(TargetGraph::Project.new(id: "cli", label: "//cli:default"))

      expect {
        graph.add_project(TargetGraph::Project.new(id: "cli", label: "//cli:other"))
      }.to raise_error(described_class::DuplicateProjectError)
    end

    it "raises when a new project's target label already exists elsewhere in the graph" do
      graph = described_class.new
      graph.add_project(TargetGraph::Project.new(id: "cli", label: "//cli:default"))

      # A second Project object that happens to resolve to the same
      # project path ends up with the same implicit default-target label.
      colliding = TargetGraph::Project.new(id: "cli-again", label: "//cli:default")

      expect { graph.add_project(colliding) }.to raise_error(described_class::DuplicateTargetError)
    end
  end

  describe "#validate!" do
    it "passes for a well-formed graph with dependency edges" do
      graph = described_class.new
      prepare = TargetGraph::Target.new(label: "//cli:prepare/deps", kind: "prepare")
      grader = TargetGraph::Target.new(label: "//cli:grade/tests", kind: "grader",
                                        dependencies: [ "//cli:default", "//cli:prepare/deps" ])
      graph.add_project(TargetGraph::Project.new(id: "cli", label: "//cli:default", targets: [ prepare, grader ]))

      expect(graph.validate!).to be(true)
    end

    it "raises when a target depends on a label that doesn't exist in the graph" do
      graph = described_class.new
      grader = TargetGraph::Target.new(label: "//cli:grade/tests", kind: "grader", dependencies: [ "//cli:missing" ])
      graph.add_project(TargetGraph::Project.new(id: "cli", label: "//cli:default", targets: [ grader ]))

      expect { graph.validate! }.to raise_error(described_class::UnknownDependencyError, /missing/)
    end

    it "raises for a direct self-dependency cycle" do
      graph = described_class.new
      looped = TargetGraph::Target.new(label: "//cli:grade/tests", kind: "grader", dependencies: [ "//cli:grade/tests" ])
      graph.add_project(TargetGraph::Project.new(id: "cli", label: "//cli:default", targets: [ looped ]))

      expect { graph.validate! }.to raise_error(described_class::DependencyCycleError)
    end

    it "raises for a multi-node dependency cycle" do
      graph = described_class.new
      a = TargetGraph::Target.new(label: "//cli:a", kind: "library", dependencies: [ "//cli:b" ])
      b = TargetGraph::Target.new(label: "//cli:b", kind: "library", dependencies: [ "//cli:a" ])
      graph.add_project(TargetGraph::Project.new(id: "cli", label: "//cli:default", targets: [ a, b ]))

      expect { graph.validate! }.to raise_error(described_class::DependencyCycleError)
    end
  end

  describe "#targets" do
    it "flattens targets across all projects" do
      graph = described_class.new
      graph.add_project(TargetGraph::Project.new(id: "cli", label: "//cli:default"))

      expect(graph.targets.map(&:label).map(&:to_s)).to contain_exactly("//:repo", "//cli:default")
    end
  end
end
