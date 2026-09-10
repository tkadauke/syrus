class TargetSelectionMissedEdgeRecorder
  KIND = "target_selection_missed_edge".freeze

  def self.record_broad_sweep_failures!(...) = new.record_broad_sweep_failures!(...)
  def self.record_ci_failures!(...) = new.record_ci_failures!(...)

  def record_broad_sweep_failures!(workflow:, failed_steps:)
    skipped_by_label = latest_skipped_selections_by_label(repository: workflow.job.repository, before_workflow: workflow)
    Array(failed_steps).each do |failed_step|
      details = failed_step.details.to_h
      target_label = details["target_label"].presence || "//:grade/#{details['name']}"
      skipped_entry = skipped_by_label[target_label]
      next unless skipped_entry

      record_warning!(
        workflow: workflow,
        step: failed_step,
        grader_name: details["name"],
        target_label: target_label,
        detected_by: "broad_target_sweep",
        skipped_entry: skipped_entry,
        failure_evidence: {
          "exit_code" => details["exit_code"],
          "timed_out" => details["timed_out"],
          "output" => details["output"].to_s.truncate(1_000)
        }.compact
      )
    end
  end

  def record_ci_failures!(repository:, sha:, failed_checks:)
    skipped_by_name = latest_skipped_selections_by_name(repository: repository)
    Array(failed_checks).each do |check|
      name = check_name(check)
      skipped_entry = skipped_by_name[name]
      next unless skipped_entry

      workflow = latest_selection_workflow(repository)
      next unless workflow

      record_warning!(
        workflow: workflow,
        step: latest_selection_step(workflow),
        grader_name: name,
        target_label: skipped_entry["target_label"],
        detected_by: "ci",
        skipped_entry: skipped_entry,
        failure_evidence: { "sha" => sha, "check" => check }.compact
      )
    end
  end

  private

  def latest_skipped_selections_by_label(repository:, before_workflow: nil)
    latest_skipped_selections(repository: repository, before_workflow: before_workflow)
      .index_by { |entry| entry["target_label"].to_s }
  end

  def latest_skipped_selections_by_name(repository:)
    latest_skipped_selections(repository: repository)
      .index_by { |entry| entry["name"].to_s }
  end

  def latest_skipped_selections(repository:, before_workflow: nil)
    workflow = latest_selection_workflow(repository, before_workflow: before_workflow)
    Array(workflow&.artifact(Steps::GraderFanout::TARGET_SELECTIONS_ARTIFACT_KEY)).select do |entry|
      entry["required"] && entry["affected"] == false
    end
  end

  def latest_selection_workflow(repository, before_workflow: nil)
    scope = Workflow.joins(:job)
      .where(jobs: { repository_id: repository.id, kind: "main_grader" })
      .where(trigger_kind: "main_grader")
      .where.not(artifacts: nil)
      .order(created_at: :desc, id: :desc)
      .limit(25)
    scope = scope.where("workflows.id < ?", before_workflow.id) if before_workflow

    scope.detect do |workflow|
      workflow.artifact("target_selection_mode").to_s != "broad" &&
        workflow.artifact(Steps::GraderFanout::TARGET_SELECTIONS_ARTIFACT_KEY).present?
    end
  end

  def latest_selection_step(workflow)
    workflow.steps.where(kind: "grader_fanout").order(created_at: :desc, id: :desc).first
  end

  def check_name(check)
    return check.to_s.presence unless check.respond_to?(:[])

    [ :name, "name", :context, "context" ].filter_map do |key|
      check[key].to_s.presence
    rescue StandardError
      nil
    end.first || check.to_s.presence
  end

  def record_warning!(workflow:, step:, grader_name:, target_label:, detected_by:, skipped_entry:, failure_evidence:)
    WorkflowWarnings.record!(
      workflow: workflow,
      step: step,
      kind: KIND,
      severity: "high",
      title: "Target selection skipped #{grader_name.inspect}, but #{detected_by.tr('_', ' ')} found a failure",
      evidence: {
        "grader_name" => grader_name,
        "target_label" => target_label,
        "detected_by" => detected_by,
        "skipped_selection" => skipped_entry,
        "failure" => failure_evidence
      },
      suggested_prompt: suggested_prompt(grader_name: grader_name, target_label: target_label, skipped_entry: skipped_entry, detected_by: detected_by)
    )
  end

  def suggested_prompt(grader_name:, target_label:, skipped_entry:, detected_by:)
    <<~PROMPT.strip
      A #{detected_by.tr('_', ' ')} found `#{grader_name}` (`#{target_label}`) failing even though the latest affected-target selection skipped it as `#{skipped_entry['reason']}`. Audit the target graph and `.syrus.yml` configuration for this repository. Add the missing dependency edge if one exists, move this grader into a nested `.syrus.yml` if it belongs to a subproject, define an explicit `project:`/`targets:` node for the code it covers, or declare a broader `when_files_changed` target scope so future affected-target selection includes it.
    PROMPT
  end
end
