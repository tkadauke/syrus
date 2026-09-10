require "pathname"

class TargetGraph
  # Compiles a repository's root `.syrus.yml` legacy primitives (`prepare`,
  # `formatters`, `generated`, `grade`) into a TargetGraph under the
  # implicit root project (DOC-20's "First Implementation Slice" step 1),
  # then does the same for every nested `.syrus.yml` discovered below the
  # root (step 2) -- each nested file becomes its own directory-scoped
  # project, with its legacy sections compiled into targets under that
  # project the exact same way the root file's sections are.
  #
  # There is no `#compile_builders!` here on purpose: `builder` is a
  # reserved TargetGraph::Target kind (see its KINDS comment) with no
  # `.syrus.yml` primitive behind it yet. A future `build:` section should
  # add a `#compile_builders!` alongside the methods below, following the
  # same per-section shape (root + nested, `scoped_source_scope` for its
  # affected-file default) -- see "The `builder` kind is reserved, not
  # compiled" in config/syrus_docs/target_graph.md.
  #
  # `Steps::GraderFanout` is the one runtime consumer so far: it calls
  # `TargetGraph#affected`/`#affected_targets` (see config/syrus_docs/
  # target_graph.md) to decide whether a root grader is affected by the
  # current diff, through its own source scope or a `deps:` dependency's.
  # `RepoPrepPlan`, `Steps::Format`, and `Steps::Generate` still don't read
  # the compiled graph, and a nested `.syrus.yml`'s formatter/generator/
  # builder/grader targets don't materialize as workflow Steps yet -- they
  # compile into the graph (so graph-level tooling and dependency closures
  # can already see them) but nothing executes them, pending a decision on
  # what directory a nested target's command should run from. Root
  # `.syrus.yml` compilation is unchanged by any of this: a repository with
  # no nested config compiles exactly as it did before nested discovery
  # existed. This class exists so operator tooling and later graph-aware
  # selection code (explicit projects/targets) have one real compiler to
  # build on instead of a graph model nothing populates.
  #
  # Step 3 of that same slice -- see #scoped_source_scope -- resolves each
  # legacy executable declaration's affected-file scope by the directory of
  # the `.syrus.yml` that declared it: a formatter/generated/grader entry's
  # own file selector, when given, is relative to that directory, and a bare
  # declaration with no selector at all defaults to the whole directory. The
  # root file's directory is the repository root, so root declarations stay
  # exactly as repo-wide as they always were.
  #
  # Grader compilation delegates to RepoGradePlan so the exact same
  # legacy-`ci:` expansion, duplicate-name detection, and failure-policy
  # defaulting apply here as they do for real grader runs -- this compiler
  # does not reimplement that logic. RepoGradePlan already accepts any
  # directory (not just the workspace root), so the same call works for a
  # nested `.syrus.yml`'s directory.
  #
  # Two different severities apply to a broken nested `.syrus.yml`, mirroring
  # how a broken root config already behaves:
  #
  # - Invalid YAML/config in one nested file (SyrusYml::ParseError) is
  #   lenient: that one file's project/targets are skipped, compilation
  #   continues for the root and every other nested file, and the problem is
  #   surfaced through Diagnostics#error (never raised from #compile).
  # - A structural collision across files -- two different nested
  #   directories resolving to the same project id, or (in principle) two
  #   targets resolving to the same label -- is a real graph-construction
  #   error and raises TargetGraph::ValidationError, exactly like any other
  #   duplicate project/target declaration.
  class Compiler
    # Low-noise summary of one compilation, meant for workflow/run log
    # output and the `target_graph_diagnostics` workflow artifact (see
    # Steps::Prepare). `source` mirrors the RepoPrepPlan/RepoGradePlan
    # convention (".syrus.yml" or "none" — no config file present at all).
    # `error`, when present, is a human-readable message naming the owning
    # `.syrus.yml` path (and target label, for validation failures) so an
    # operator can find the offending config without reading source.
    Diagnostics = Data.define(:source, :owner_config_path, :target_labels, :project_count, :error) do
      def error?
        !error.nil?
      end

      def to_h
        {
          "source" => source,
          "owner_config_path" => owner_config_path,
          "target_labels" => target_labels,
          "target_count" => target_labels.size,
          "project_count" => project_count,
          "error" => error
        }
      end
    end

    def self.compile(workspace_path)
      new(workspace_path).compile
    end

    def self.diagnose(workspace_path)
      new(workspace_path).diagnose
    end

    def initialize(workspace_path)
      @workspace_path = Pathname.new(workspace_path)
    end

    def compile
      graph = TargetGraph.new(root_project: root_project_override)
      compile_explicit_targets!(graph)
      compile_prepare!(graph)
      compile_formatters!(graph)
      compile_generated!(graph)
      compile_graders!(graph)
      compile_nested_configs!(graph)
      graph.validate!
      graph
    end

    # Never raises -- callers such as Steps::Prepare use this for
    # low-stakes diagnostics and must not fail a workflow over a
    # diagnostics-only read. A parse or validation failure -- root or
    # nested -- is reported through `Diagnostics#error` instead of
    # propagating.
    def diagnose
      graph = compile
      Diagnostics.new(
        source: config_present? ? owner_config_path : "none",
        owner_config_path: owner_config_path,
        target_labels: graph.targets.keys.sort,
        project_count: graph.projects.size,
        error: combined_error
      )
    rescue StandardError => e
      Diagnostics.new(
        source: owner_config_path,
        owner_config_path: owner_config_path,
        target_labels: [],
        project_count: nil,
        error: "#{owner_config_path}: #{e.message}"
      )
    end

    private

    attr_reader :workspace_path, :parse_error

    def config
      return @config if defined?(@config)

      @config = config_present? ? SyrusYml.load_repo(workspace_path) : nil
    rescue SyrusYml::ParseError => e
      @parse_error = e
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

    # An explicit `project:` block in the root `.syrus.yml` (DOC-20 "Explicit
    # Projects" applied to the implicit root project mentioned in
    # TargetGraph::Project#root?) may only customize label/kind: the root
    # project's id and path are structural (there is exactly one repository
    # root), so a declared `project.id`/`project.path` that disagrees with
    # that is a config error naming the offending file, not a silent
    # override -- the same posture as every other nested/root collision this
    # compiler reports.
    def root_project_override
      declared = config&.project
      return nil unless declared

      if declared.id && declared.id != root_project_id
        raise TargetGraph::ValidationError,
          "#{owner_config_path} project.id must be #{root_project_id.inspect} for the root .syrus.yml; got #{declared.id.inspect}"
      end
      if declared.path
        raise TargetGraph::ValidationError,
          "#{owner_config_path} project.path must be empty for the root .syrus.yml; got #{declared.path.inspect}"
      end

      TargetGraph::Project.new(
        id: root_project_id,
        label: declared.label || "Repository",
        kind: declared.kind,
        path: "",
        owner_config_path: owner_config_path
      )
    end

    def label_for(name, package: "")
      TargetGraph::Label.new(package: package, name: name)
    end

    # Resolves the effective affected-file scope for one legacy executable
    # declaration (a formatter's `files`, a generated entry's `sources`, a
    # grader's `when_files_changed`) per DOC-20's "First Implementation
    # Slice" step 3: an explicit selector's globs are relative to the
    # declaring `.syrus.yml`'s own directory, so they're resolved by
    # prefixing them with `package`; a declaration with no explicit selector
    # defaults to that entire directory instead of Target's own unscoped
    # default. The root file's directory is the repository root (`package`
    # is ""), so both rules collapse to today's repo-wide behavior there --
    # nothing here branches on "is this the root config."
    #
    # Prepare is deliberately not routed through this: it has no
    # file-selector primitive and stays the unconditional pre-implementation
    # baseline (see #compile_prepare!).
    def scoped_source_scope(package, explicit_patterns)
      patterns = Array(explicit_patterns).map(&:to_s).map(&:strip).reject(&:empty?)
      patterns = [ "**/*" ] if patterns.empty? && package.present?

      patterns.map { |pattern| package.present? ? "#{package}/#{pattern}" : pattern }
    end

    # Discovers nested `.syrus.yml` files below the workspace root
    # (TargetGraph::NestedConfigDiscovery) and compiles each one into its
    # own directory-scoped project plus prepare/formatter/generator/grader
    # targets, using exactly the same per-section compile methods the root
    # config uses above. Nested files are visited in NestedConfigDiscovery's
    # deterministic (path-sorted) order, always after the root config has
    # already been compiled, so a repository's target graph never depends on
    # filesystem iteration order.
    def compile_nested_configs!(graph)
      @nested_parse_errors = []
      declared_project_ids = { root_project_id => owner_config_path }

      nested_relative_dirs.each do |relative_dir|
        nested_owner_config_path = "#{relative_dir}/#{SyrusYml::CONFIG_FILE}"

        begin
          nested_config = SyrusYml.load_file(workspace_path.join(relative_dir, SyrusYml::CONFIG_FILE))
        rescue SyrusYml::ParseError => e
          @nested_parse_errors << "#{nested_owner_config_path}: #{e.message}"
          next
        end

        begin
          project_id = nested_project_id(relative_dir, nested_config)
        rescue ArgumentError => e
          @nested_parse_errors << "#{nested_owner_config_path}: #{e.message}"
          next
        end

        if (existing_owner = declared_project_ids[project_id])
          raise TargetGraph::ValidationError,
            "#{nested_owner_config_path} and #{existing_owner} both resolve to project id #{project_id.inspect}; " \
            "rename one of the directories or declare a distinct project.id"
        end
        declared_project_ids[project_id] = nested_owner_config_path

        declared_project = nested_config.project
        graph.add_project(
          TargetGraph::Project.new(
            id: project_id,
            label: declared_project&.label || relative_dir,
            kind: declared_project&.kind,
            path: declared_project&.path || relative_dir,
            owner_config_path: nested_owner_config_path
          )
        )

        compile_explicit_targets!(graph, syrus_config: nested_config, package: relative_dir, project_id: project_id, config_path: nested_owner_config_path)
        compile_prepare!(graph, syrus_config: nested_config, package: relative_dir, project_id: project_id, config_path: nested_owner_config_path)
        compile_formatters!(graph, syrus_config: nested_config, package: relative_dir, project_id: project_id, config_path: nested_owner_config_path)
        compile_generated!(graph, syrus_config: nested_config, package: relative_dir, project_id: project_id, config_path: nested_owner_config_path)
        compile_graders!(graph, syrus_workspace_path: workspace_path.join(relative_dir), package: relative_dir, project_id: project_id, config_path: nested_owner_config_path)
      end
    end

    def nested_relative_dirs
      @nested_relative_dirs ||= TargetGraph::NestedConfigDiscovery.call(workspace_path)
    end

    # An explicit `project.id` in the nested file (already charset-validated
    # by SyrusYml::PROJECT_ID_PATTERN, the same charset as
    # TargetGraph::Label::SEGMENT_PATTERN) always wins over the
    # directory-derived default -- this is exactly the "non-trivial layout"
    # escape hatch DOC-20 describes: a directory whose implied id collides
    # with another, or whose path just isn't the id an operator wants, can
    # declare a different one.
    #
    # Without an explicit id, collapse the directory's path segments into one
    # the same way a label's package segments already render (`cli/tools` ->
    # `cli-tools`). A directory name outside that charset can't become a
    # project id at all; that is reported as an invalid declaration for this
    # one file rather than raised, matching how any other malformed nested
    # `.syrus.yml` is handled.
    def nested_project_id(relative_dir, nested_config)
      return nested_config.project.id if nested_config.project&.id

      id = relative_dir.tr("/", "-")
      unless id.match?(TargetGraph::Label::SEGMENT_PATTERN)
        raise ArgumentError, "directory #{relative_dir.inspect} can't become a project id (only letters, digits, _ and - are allowed)"
      end

      id
    end

    def combined_error
      messages = []
      messages << "#{owner_config_path}: #{parse_error.message}" if parse_error
      messages.concat(Array(@nested_parse_errors))
      messages.join("; ").presence
    end

    # Root prepare is left out of the dependency graph on purpose: it is the
    # legacy pre-implementation baseline (runs unconditionally before every
    # workflow step, not selectively per affected target), so wiring it as a
    # dependency of every root executable target would assert a selection
    # relationship that doesn't exist yet. See DOC-20 "Prepare Semantics."
    # The same treatment applies to a nested `.syrus.yml`'s own `prepare:`.
    def compile_prepare!(graph, syrus_config: config, package: "", project_id: root_project_id, config_path: owner_config_path)
      return unless syrus_config
      return unless syrus_config.prepare.is_a?(Array)

      commands = syrus_config.prepare.map(&:to_s).map(&:strip).reject(&:empty?)
      return if commands.empty?

      graph.add_target(
        TargetGraph::Target.new(
          label: label_for("prepare", package: package),
          kind: "prepare",
          project_id: project_id,
          command: commands.join(" && "),
          owner_config_path: config_path,
          metadata: { "commands" => commands }
        )
      )
    end

    def compile_explicit_targets!(graph, syrus_config: config, package: "", project_id: root_project_id, config_path: owner_config_path)
      return unless syrus_config

      syrus_config.targets.each do |target|
        graph.add_target(
          TargetGraph::Target.new(
            label: label_for(target.name, package: package),
            kind: target.kind,
            project_id: project_id,
            source_scope: scoped_source_scope(package, target.sources),
            command: target.command,
            dependencies: resolved_dependencies(target.deps, package: package),
            timeout_minutes: positive_timeout(target.timeout_minutes),
            owner_config_path: config_path,
            metadata: target.metadata
          )
        )
      end
    end

    def compile_formatters!(graph, syrus_config: config, package: "", project_id: root_project_id, config_path: owner_config_path)
      return unless syrus_config
      return unless syrus_config.formatters.is_a?(Array)

      syrus_config.formatters.each_with_index do |formatter, index|
        graph.add_target(
          TargetGraph::Target.new(
            label: label_for("format/#{index}", package: package),
            kind: "formatter",
            project_id: project_id,
            source_scope: scoped_source_scope(package, formatter.files),
            command: formatter.command,
            dependencies: legacy_dependencies(formatter.deps, package: package),
            owner_config_path: config_path
          )
        )
      end
    end

    def compile_generated!(graph, syrus_config: config, package: "", project_id: root_project_id, config_path: owner_config_path)
      return unless syrus_config
      return unless syrus_config.generated.is_a?(Array)

      syrus_config.generated.each_with_index do |entry, index|
        graph.add_target(
          TargetGraph::Target.new(
            label: label_for("generate/#{index}", package: package),
            kind: "generator",
            project_id: project_id,
            source_scope: scoped_source_scope(package, entry.sources),
            command: entry.command,
            dependencies: legacy_dependencies(entry.deps, package: package),
            owner_config_path: config_path,
            metadata: { "generates" => entry.generates, "codegen_ignore" => entry.codegen_ignore }
          )
        )
      end
    end

    def compile_graders!(graph, syrus_workspace_path: workspace_path, package: "", project_id: root_project_id, config_path: owner_config_path)
      RepoGradePlan.for(syrus_workspace_path).graders.each do |grader|
        graph.add_target(
          TargetGraph::Target.new(
            label: label_for("grade/#{grader.name}", package: package),
            kind: "grader",
            project_id: project_id,
            source_scope: scoped_source_scope(package, grader.when_files_changed),
            command: grader.command,
            dependencies: legacy_dependencies(grader.deps, package: package),
            phases: grader.phases,
            required: grader.required,
            timeout_minutes: positive_timeout(grader.timeout_minutes),
            owner_config_path: config_path,
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

    def legacy_dependencies(raw_dependencies, package:)
      [ TargetGraph.root_label, *resolved_dependencies(raw_dependencies, package: package) ].uniq
    end

    def resolved_dependencies(raw_dependencies, package:)
      Array(raw_dependencies).map { |dependency| TargetGraph::Label.resolve(dependency, package: package) }
    rescue TargetGraph::Label::ParseError => e
      raise TargetGraph::ValidationError, e.message
    end
  end
end
