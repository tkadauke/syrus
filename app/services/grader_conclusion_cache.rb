require "digest"

class GraderConclusionCache
  ARTIFACT_FINGERPRINT_KEY = "grade_plan_fingerprint".freeze
  ARTIFACT_CACHE_HIT_KEY = "grader_conclusion_cache_hit".freeze
  ARTIFACT_HEAD_SHA_KEY = "grade_plan_head_sha".freeze

  def self.fingerprint_for_plan(plan, target_graph: nil)
    fingerprint_for_graders(plan.graders, target_graph: target_graph)
  end

  def self.fingerprint_for_steps(grader_steps)
    payload = grader_steps.map do |step|
      details = step.details || {}
      {
        "name" => details["name"].to_s,
        "command" => details["command"].to_s,
        "required" => !!details["required"],
        "timeout_minutes" => details["timeout_minutes"].to_i,
        "when_files_changed" => Array(details["when_files_changed"]).map(&:to_s).sort,
        "prepare_commands" => Array(details["prepare_commands"]).map(&:to_s)
      }
    end

    digest(payload)
  end

  def self.successful?(repository:, commit_sha:, grader_fingerprint:)
    return false if repository.blank? || commit_sha.blank? || grader_fingerprint.blank?

    GraderConclusion.aggregate
                    .passed
                    .where(repository: repository, commit_sha: commit_sha, grader_fingerprint: grader_fingerprint)
                    .exists?
  end

  def self.latest_success(repository:, commit_sha:, grader_fingerprint:)
    return nil if repository.blank? || commit_sha.blank? || grader_fingerprint.blank?

    GraderConclusion.aggregate
                    .passed
                    .where(repository: repository, commit_sha: commit_sha, grader_fingerprint: grader_fingerprint)
                    .latest_first
                    .first
  end

  def self.failed?(repository:, commit_sha:, grader_fingerprint:)
    return false if repository.blank? || commit_sha.blank? || grader_fingerprint.blank?

    GraderConclusion.aggregate
                    .failed
                    .where(repository: repository, commit_sha: commit_sha, grader_fingerprint: grader_fingerprint)
                    .exists?
  end

  # Convenience for repair/reconciliation code that only has a Workflow in
  # hand: reads the head SHA + fingerprint that GraderFanout already stamped
  # onto workflow artifacts for the current grade iteration.
  def self.failed_for_workflow?(workflow)
    return false unless workflow

    failed?(
      repository: workflow.job&.repository,
      commit_sha: workflow.artifact(ARTIFACT_HEAD_SHA_KEY),
      grader_fingerprint: workflow.artifact(ARTIFACT_FINGERPRINT_KEY)
    )
  end

  def self.record!(workflow:, run:, step:, commit_sha:, grader_steps:, aggregate_status:, grader_fingerprint: nil, carried_forward: [])
    return if commit_sha.blank? || (grader_steps.empty? && carried_forward.empty?)

    fingerprint = grader_fingerprint.presence || fingerprint_for_steps(grader_steps)
    checked_at = Time.current

    GraderConclusion.transaction do
      grader_steps.each do |grader_step|
        details = grader_step.details || {}
        GraderConclusion.create!(
          repository: workflow.job.repository,
          job: workflow.job,
          workflow: workflow,
          step: grader_step,
          run: grader_step.runs.order(:created_at).last,
          commit_sha: commit_sha,
          grader_fingerprint: fingerprint,
          grader_name: details["name"].presence || "grader-#{grader_step.id}",
          required: details.key?("required") ? !!details["required"] : nil,
          status: status_for_step(grader_step),
          exit_code: details["exit_code"],
          duration_s: details["duration_s"],
          timed_out: !!details["timed_out"],
          log_path: details["log_path"],
          log_bytes: details["log_bytes"],
          checked_at: checked_at,
          metadata: metadata_for(workflow: workflow, step: grader_step)
        )

        record_target_health!(
          workflow: workflow,
          step: grader_step,
          run: grader_step.runs.order(:created_at).last,
          commit_sha: commit_sha,
          status: status_for_step(grader_step),
          details: details,
          checked_at: checked_at
        )
      end

      # rerun_only_failed skipped these graders this iteration because they
      # already passed last time — record a per-iteration conclusion reusing
      # that prior result so grader-history consumers don't see a gap for
      # them on an iteration where they legitimately didn't run.
      carried_forward.each do |entry|
        GraderConclusion.create!(
          repository: workflow.job.repository,
          job: workflow.job,
          workflow: workflow,
          step: step,
          run: run,
          commit_sha: commit_sha,
          grader_fingerprint: fingerprint,
          grader_name: entry["name"].presence || "grader-carried-forward",
          required: entry.key?("required") ? !!entry["required"] : nil,
          status: "passed",
          exit_code: entry["exit_code"],
          duration_s: entry["duration_s"],
          timed_out: false,
          log_path: entry["log_path"],
          log_bytes: entry["log_bytes"],
          checked_at: checked_at,
          metadata: metadata_for(workflow: workflow, step: step).merge(
            "carried_forward" => true,
            "source_iteration" => entry["source_iteration"]
          ).compact
        )
      end

      GraderConclusion.create!(
        repository: workflow.job.repository,
        job: workflow.job,
        workflow: workflow,
        step: step,
        run: run,
        commit_sha: commit_sha,
        grader_fingerprint: fingerprint,
        grader_name: GraderConclusion::AGGREGATE_NAME,
        required: true,
        status: aggregate_status,
        timed_out: aggregate_status == "timed_out",
        checked_at: checked_at,
        metadata: {
          "trigger_kind" => workflow.trigger_kind,
          "iteration" => run.iteration,
          "loop_id" => step.loop_id,
          "grader_count" => grader_steps.size + carried_forward.size
        }.compact
      )
    end
  rescue StandardError => e
    Rails.logger.warn("[GraderConclusionCache] record failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
    nil
  end

  def self.status_for_step(step)
    state = step.visible_state
    return "passed" if state == "succeeded"
    return "timed_out" if GraderFailureSignal.timeout_like_step?(step)
    return "cancelled" if state == "cancelled"
    return "failed" if state == "failed"

    "inconclusive"
  end

  def self.aggregate_status_for(failed_required)
    failed_required = Array(failed_required)
    return "passed" if failed_required.empty?
    return "timed_out" if failed_required.all? { |grader_step| GraderFailureSignal.timeout_like_step?(grader_step) }

    "failed"
  end

  def self.fingerprint_for_graders(graders, target_graph: nil)
    payload = {
      "graders" => Array(graders).map do |grader|
        {
          "name" => grader.name.to_s,
          "command" => grader.command.to_s,
          "phases" => Array(grader.phases).map(&:to_s).sort,
          "required" => !!grader.required,
          "timeout_minutes" => grader.timeout_minutes.to_i,
          "when_files_changed" => Array(grader.when_files_changed).map(&:to_s).sort,
          "deps" => Array(grader.deps).map(&:to_s).sort,
          "junit_output" => grader.junit_output.to_s,
          "failures" => grader.failures.to_s,
          "metadata" => normalize_hash(grader.metadata)
        }
      end,
      "target_graph" => target_graph_payload(target_graph)
    }

    digest(payload)
  end

  def self.target_graph_payload(target_graph)
    return nil unless target_graph

    target_graph.targets.values.map do |target|
      {
        "label" => target.label.to_s,
        "kind" => target.kind,
        "project_id" => target.project_id,
        "source_scope" => Array(target.source_scope).map(&:to_s).sort,
        "command" => target.command.to_s,
        "dependencies" => Array(target.dependencies).map(&:to_s).sort,
        "phases" => Array(target.phases).map(&:to_s).sort,
        "required" => !!target.required,
        "timeout_minutes" => target.timeout_minutes.to_i,
        "owner_config_path" => target.owner_config_path.to_s,
        "metadata" => normalize_hash(target.metadata)
      }
    end.sort_by { |entry| entry["label"] }
  end
  private_class_method :target_graph_payload

  def self.record_target_health!(workflow:, step:, run:, commit_sha:, status:, details:, checked_at:)
    target_label = details["target_label"].presence || details["projected_target_label"].presence
    return if target_label.blank?

    TargetHealthRecorder.record!(
      repository: workflow.job.repository,
      workflow: workflow,
      step: step,
      run: run,
      target_label: target_label,
      project_id: project_id_for_target_label(target_label),
      commit_sha: commit_sha,
      input_fingerprint: input_fingerprint_for(commit_sha: commit_sha, details: details),
      command_fingerprint: command_fingerprint_for(details: details, target_label: target_label),
      environment_fingerprint: environment_fingerprint_for(details: details),
      status: status,
      checked_at: checked_at,
      duration_s: details["duration_s"],
      exit_code: details["exit_code"],
      log_path: details["log_path"],
      log_bytes: details["log_bytes"],
      artifacts: target_artifacts_for(details),
      metadata: metadata_for(workflow: workflow, step: step).merge(
        "grader_name" => details["name"],
        "required" => details["required"]
      ).compact
    )
  end
  private_class_method :record_target_health!

  def self.project_id_for_target_label(target_label)
    label = TargetGraph::Label.parse(target_label)
    label.package.presence || TargetGraph::ROOT_PROJECT_ID
  rescue TargetGraph::Label::ParseError
    TargetGraph::ROOT_PROJECT_ID
  end
  private_class_method :project_id_for_target_label

  def self.input_fingerprint_for(commit_sha:, details:)
    details.dig("target_fingerprints", "input_fingerprint").presence ||
      details.dig("source_snapshot", "fingerprint").presence ||
      details.dig("source_snapshot", "tree_sha").presence ||
      details.dig("source_snapshot", "source_sha").presence ||
      commit_sha
  end
  private_class_method :input_fingerprint_for

  def self.command_fingerprint_for(details:, target_label:)
    details.dig("target_fingerprints", "command_fingerprint").presence ||
      details["projected_target_fingerprint"].presence ||
      digest(
        "target_label" => target_label,
        "name" => details["name"].to_s,
        "command" => details["command"].to_s,
        "required" => !!details["required"],
        "timeout_minutes" => details["timeout_minutes"].to_i,
        "when_files_changed" => Array(details["when_files_changed"]).map(&:to_s).sort,
        "phase" => details["phase"].to_s
      )
  end
  private_class_method :command_fingerprint_for

  def self.environment_fingerprint_for(details:)
    return details.dig("target_fingerprints", "environment_fingerprint") if details.dig("target_fingerprints", "environment_fingerprint").present?

    digest(
      "prepare_targets" => Array(details["prepare_targets"]).map { |entry| entry.to_h.sort.to_h },
      "prepare_commands" => Array(details["prepare_commands"]).map(&:to_s)
    )
  end
  private_class_method :environment_fingerprint_for

  def self.target_artifacts_for(details)
    {
      "log_path" => details["log_path"],
      "log_bytes" => details["log_bytes"],
      "output_excerpt" => details["output"]
    }.compact
  end
  private_class_method :target_artifacts_for

  def self.digest(payload)
    Digest::SHA256.hexdigest(JSON.generate(payload))
  end
  private_class_method :digest

  def self.normalize_hash(value)
    value.to_h.transform_keys(&:to_s).sort.to_h.transform_values do |entry|
      case entry
      when Hash
        normalize_hash(entry)
      when Array
        entry.map { |item| item.is_a?(Hash) ? normalize_hash(item) : item }
      else
        entry
      end
    end
  end
  private_class_method :normalize_hash

  def self.metadata_for(workflow:, step:)
    {
      "trigger_kind" => workflow.trigger_kind,
      "iteration" => step.iteration,
      "loop_id" => step.loop_id
    }.compact
  end
  private_class_method :metadata_for
end
