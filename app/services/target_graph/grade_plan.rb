class TargetGraph
  class GradePlan
    def self.for(workspace_path:, graph:)
      new(workspace_path: workspace_path, graph: graph).for
    end

    def initialize(workspace_path:, graph:)
      @workspace_path = workspace_path
      @graph = graph
    end

    def for
      root_plan = RepoGradePlan.for(workspace_path)
      graders = graph.targets.values
        .select { |target| target.kind == "grader" && target.executable? }
        .map { |target| grader_for_target(target) }

      RepoGradePlan::Result.new(
        graders: graders,
        source: graph.projects.size > 1 ? ".syrus.yml + nested .syrus.yml" : root_plan.source,
        note: graders.empty? ? root_plan.note : nil,
        max_iterations: root_plan.max_iterations,
        rerun_only_failed: root_plan.rerun_only_failed
      )
    end

    private

    attr_reader :workspace_path, :graph

    def grader_for_target(target)
      metadata = target.metadata.to_h.deep_stringify_keys.merge(
        "target_label" => target.label.to_s,
        "owner_config_path" => target.owner_config_path
      ).compact

      RepoGradePlan::Grader.new(
        name: grader_name_for_target(target),
        command: target.command,
        phases: target.phases,
        description: metadata["description"],
        required: target.required,
        timeout_minutes: target.timeout_minutes,
        when_files_changed: target.source_scope,
        junit_output: metadata["junit_output"],
        failures: metadata["failures"],
        base_retry: metadata["base_retry"],
        deps: [],
        metadata: metadata
      )
    end

    def grader_name_for_target(target)
      name = target.label.name.delete_prefix("grade/")
      return name if target.label.root?

      "#{target.label.package.tr('/', '-')}-#{name.tr('/', '-')}"
    end
  end
end
