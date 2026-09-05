require "pathname"

class TargetGraph
  # Compiles a repository's root `.syrus.yml` legacy primitives (`prepare`,
  # `formatters`, `generated`, `grade`) into a TargetGraph under the
  # implicit root project, per DOC-20's "First Implementation Slice" step 1.
  #
  # This is representation only: nothing in the runtime prepare/format/
  # generate/grader pipelines (RepoPrepPlan, Steps::Format, Steps::Generate,
  # RepoGradePlan/grader_fanout) reads from the compiled graph yet, and this
  # class does not change what those pipelines do. It exists so operator
  # tooling and later graph-aware selection code (nested `.syrus.yml`
  # discovery, explicit projects/targets) have one real compiler to build on
  # instead of a graph model nothing populates.
  #
  # Grader compilation delegates to RepoGradePlan so the exact same
  # legacy-`ci:` expansion, duplicate-name detection, and failure-policy
  # defaulting apply here as they do for real grader runs -- this compiler
  # does not reimplement that logic.
  class Compiler
    def self.compile(workspace_path)
      new(workspace_path).compile
    end

    def initialize(workspace_path)
      @workspace_path = Pathname.new(workspace_path)
    end

    def compile
      graph = TargetGraph.new
      compile_prepare!(graph)
      compile_formatters!(graph)
      compile_generated!(graph)
      compile_graders!(graph)
      graph.validate!
      graph
    end

    private

    attr_reader :workspace_path

    def config
      return @config if defined?(@config)

      @config = config_present? ? SyrusYml.load_repo(workspace_path) : nil
    rescue SyrusYml::ParseError
      @config = nil
    end

    def config_present?
      workspace_path.join(SyrusYml::CONFIG_FILE).exist?
    end

    def owner_config_path
      SyrusYml::CONFIG_FILE
    end

    def root_project_id
      TargetGraph::ROOT_PROJECT_ID
    end

    def label_for(name)
      TargetGraph::Label.root(name)
    end

    # Root prepare is left out of the dependency graph on purpose: it is the
    # legacy pre-implementation baseline (runs unconditionally before every
    # workflow step, not selectively per affected target), so wiring it as a
    # dependency of every root executable target would assert a selection
    # relationship that doesn't exist yet. See DOC-20 "Prepare Semantics."
    def compile_prepare!(graph)
      return unless config
      return unless config.prepare.is_a?(Array)

      commands = config.prepare.map(&:to_s).map(&:strip).reject(&:empty?)
      return if commands.empty?

      graph.add_target(
        TargetGraph::Target.new(
          label: label_for("prepare"),
          kind: "prepare",
          project_id: root_project_id,
          command: commands.join(" && "),
          owner_config_path: owner_config_path,
          metadata: { "commands" => commands }
        )
      )
    end

    def compile_formatters!(graph)
      return unless config
      return unless config.formatters.is_a?(Array)

      config.formatters.each_with_index do |formatter, index|
        graph.add_target(
          TargetGraph::Target.new(
            label: label_for("format/#{index}"),
            kind: "formatter",
            project_id: root_project_id,
            source_scope: formatter.files,
            command: formatter.command,
            dependencies: [ TargetGraph.root_label ],
            owner_config_path: owner_config_path
          )
        )
      end
    end

    def compile_generated!(graph)
      return unless config
      return unless config.generated.is_a?(Array)

      config.generated.each_with_index do |entry, index|
        graph.add_target(
          TargetGraph::Target.new(
            label: label_for("generate/#{index}"),
            kind: "generator",
            project_id: root_project_id,
            source_scope: entry.sources,
            command: entry.command,
            dependencies: [ TargetGraph.root_label ],
            owner_config_path: owner_config_path,
            metadata: { "generates" => entry.generates, "codegen_ignore" => entry.codegen_ignore }
          )
        )
      end
    end

    def compile_graders!(graph)
      RepoGradePlan.for(workspace_path).graders.each do |grader|
        graph.add_target(
          TargetGraph::Target.new(
            label: label_for("grade/#{grader.name}"),
            kind: "grader",
            project_id: root_project_id,
            source_scope: grader.when_files_changed,
            command: grader.command,
            dependencies: [ TargetGraph.root_label ],
            phases: grader.phases,
            required: grader.required,
            timeout_minutes: positive_timeout(grader.timeout_minutes),
            owner_config_path: owner_config_path,
            metadata: {
              "description" => grader.description,
              "junit_output" => grader.junit_output,
              "failures" => grader.failures
            }.merge(grader.metadata).compact
          )
        )
      end
    end

    # RepoGradePlan/SyrusYml don't enforce timeout_minutes > 0 the way
    # TargetGraph::Target does; a non-positive value is nonsensical but
    # shouldn't blow up compilation of an otherwise-valid legacy config.
    def positive_timeout(timeout_minutes)
      timeout_minutes if timeout_minutes.is_a?(Integer) && timeout_minutes.positive?
    end
  end
end
