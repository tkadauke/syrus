class TargetHealthReuse
  Result = Data.define(:target, :fingerprints, :record, :dependency_results) do
    def reusable?
      healthy_record? && dependency_results.all?(&:reusable?)
    end

    def reason
      return "latest target health record passed" if reusable?
      return "target health is unknown" unless record
      return "latest target health is #{record.status}" unless healthy_record?

      dependency = dependency_results.find { |result| !result.reusable? }
      "dependency #{dependency.target.label} #{dependency.reason}"
    end

    def record_refs
      ([ record ] + dependency_results.flat_map(&:record_refs)).compact.uniq(&:id).map do |health|
        {
          "target_health_record_id" => health.id,
          "target_label" => health.target_label,
          "project_id" => health.project_id,
          "commit_sha" => health.commit_sha,
          "status" => health.status,
          "checked_at" => health.checked_at&.iso8601
        }.compact
      end
    end

    private

    def healthy_record?
      record&.healthy?
    end
  end

  def initialize(repository:, graph:, workspace_path:)
    @repository = repository
    @graph = graph
    @workspace_path = workspace_path
    @results = {}
  end

  def for_target(label)
    target = graph.target(label)
    raise TargetGraph::ValidationError, "unknown target #{label}" unless target

    result_for(target)
  end

  private

  attr_reader :repository, :graph, :workspace_path

  def result_for(target)
    @results[target.label.to_s] ||= begin
      fingerprints = TargetGraph::Fingerprints.for_target(
        workspace_path: workspace_path,
        graph: graph,
        label: target.label
      )
      Result.new(
        target: target,
        fingerprints: fingerprints,
        record: latest_record_for(target, fingerprints),
        dependency_results: executable_dependency_results_for(target)
      )
    end
  end

  def executable_dependency_results_for(target)
    graph.dependency_closure_for(target.label).filter_map do |dependency_label|
      dependency = graph.target(dependency_label)
      result_for(dependency) if dependency&.executable?
    end
  end

  def latest_record_for(target, fingerprints)
    TargetHealthRecord.latest_for_reusable_inputs(
      repository: repository,
      target_label: target.label.to_s,
      input_fingerprint: fingerprints.input_fingerprint,
      command_fingerprint: fingerprints.command_fingerprint,
      environment_fingerprint: fingerprints.environment_fingerprint
    )
  end
end
