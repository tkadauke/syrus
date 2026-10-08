class TargetHealthReuse
  Result = Data.define(:target, :fingerprints, :record, :dependency_results, :environment_mismatch_record) do
    def reusable?
      healthy_record? && dependency_results.all?(&:reusable?)
    end

    def reason
      return "latest target health record passed" if reusable?
      return environment_mismatch_reason if environment_mismatch_record && !record
      return "target health is unknown" unless record
      return "latest target health is #{record.status}" unless healthy_record?

      dependency = dependency_results.find { |result| !result.reusable? }
      "dependency #{dependency.target.label} #{dependency.reason}"
    end

    def record_refs
      health_records.map do |health|
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

    def health_records
      ([ record ] + dependency_results.flat_map(&:health_records)).compact.uniq(&:id)
    end

    private

    def healthy_record?
      record&.healthy?
    end

    def environment_mismatch_reason
      cached = environment_summary(environment_mismatch_record.metadata.to_h)
      current = environment_summary(fingerprints.metadata.to_h)
      "target health environment/capability mismatch (cached #{cached}; current #{current})"
    end

    def environment_summary(metadata)
      environment = metadata["target_fingerprint_metadata"].presence ||
        metadata.dig("target_fingerprints", "metadata").presence ||
        metadata["fingerprint_metadata"].presence ||
        metadata
      worker = environment.dig("worker_environment") || environment.dig("environment", "worker_environment") || {}
      capabilities = worker["capabilities"].presence || {}
      runtime = worker["runtime"].presence || {}
      [
        capability_token(capabilities, "os"),
        capability_token(capabilities, "arch"),
        capability_token(capabilities, "toolchain") || capability_token(capabilities, "toolchains"),
        capability_token(capabilities, "runtime") || capability_token(capabilities, "runtimes"),
        runtime["ruby_platform"].presence
      ].compact_blank.join(" ")
    end

    def capability_token(capabilities, key)
      values = Array(capabilities[key]).map(&:to_s).reject(&:blank?)
      return nil if values.empty?

      "#{key}=#{values.join('+')}"
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
        dependency_results: executable_dependency_results_for(target),
        environment_mismatch_record: latest_environment_mismatch_record_for(target, fingerprints)
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

  def latest_environment_mismatch_record_for(target, fingerprints)
    TargetHealthRecord
      .for_reusable_command_inputs(
        repository: repository,
        target_label: target.label.to_s,
        input_fingerprint: fingerprints.input_fingerprint,
        command_fingerprint: fingerprints.command_fingerprint
      )
      .where.not(environment_fingerprint: fingerprints.environment_fingerprint)
      .latest_first
      .first
  end
end
