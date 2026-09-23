require "rails_helper"
require "tmpdir"

RSpec.describe TargetGraph::GradePlan do
  around do |ex|
    Syrus::PluginRegistry.reset!
    Dir.mktmpdir("syrus-target-graph-grade-plan") { |dir| @dir = dir; ex.run }
    Syrus::PluginRegistry.reset!
  end

  describe ".for" do
    it "prefixes a nested grader's resolved display_name with its project's declared label" do
      write("plugins/rails/.syrus.yml", <<~YAML)
        project:
          id: rails
          label: "rails plugin"
        grade:
          - name: rspec-focused
            run: bin/rspec
            display_name: "RSpec (focused)"
      YAML

      graph = TargetGraph::Compiler.compile(@dir)
      graders = described_class.for(workspace_path: @dir, graph: graph).graders

      grader = graders.find { |candidate| candidate.name == "plugins-rails-rspec-focused" }
      expect(grader.display_name).to eq("rails plugin: RSpec (focused)")
    end

    it "falls back to the directory-derived project label when no project.label is declared" do
      write("plugins/rails/.syrus.yml", <<~YAML)
        grade:
          - name: rspec-focused
            run: bin/rspec
            display_name: "RSpec (focused)"
      YAML

      graph = TargetGraph::Compiler.compile(@dir)
      graders = described_class.for(workspace_path: @dir, graph: graph).graders

      grader = graders.find { |candidate| candidate.name == "plugins-rails-rspec-focused" }
      expect(grader.display_name).to eq("plugins/rails: RSpec (focused)")
    end

    it "never prefixes a root-level grader, even when the root project declares a label" do
      write(".syrus.yml", <<~YAML)
        project:
          label: Syrus
        grade:
          - name: tests
            run: bin/rspec
            display_name: "RSpec"
      YAML

      graph = TargetGraph::Compiler.compile(@dir)
      graders = described_class.for(workspace_path: @dir, graph: graph).graders

      grader = graders.find { |candidate| candidate.name == "tests" }
      expect(grader.display_name).to eq("RSpec")
    end

    it "leaves display_name nil for a nested grader with no explicit or type-generated label" do
      write("plugins/rails/.syrus.yml", <<~YAML)
        grade:
          - name: schema-check
            run: bin/check-schema
      YAML

      graph = TargetGraph::Compiler.compile(@dir)
      graders = described_class.for(workspace_path: @dir, graph: graph).graders

      grader = graders.find { |candidate| candidate.name == "plugins-rails-schema-check" }
      expect(grader.display_name).to be_nil
    end
  end

  def write(rel, contents)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end
end
