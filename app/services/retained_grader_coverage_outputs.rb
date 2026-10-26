# Resolves durable coverage blobs from the grader iteration that actually
# satisfied the workflow's final grader_collect barrier.
class RetainedGraderCoverageOutputs
  Output = Data.define(:attachment, :artifact, :format, :grader_name, :workspace_path, :run_id)

  def self.for(workflow)
    new(workflow).outputs
  end

  def initialize(workflow)
    @workflow = workflow
  end

  def outputs
    steps = selected_steps
    runs_by_step_id = latest_successful_runs_by_step_id(steps)
    attachments_by_run_id = coverage_attachments_by_run_id(runs_by_step_id.values)

    steps.flat_map do |grader_step|
      latest_run = runs_by_step_id[grader_step.id]
      Array(attachments_by_run_id[latest_run&.id]).filter_map do |attachment|
        metadata = attachment.blob.metadata.to_h
        next unless metadata["source_snapshot_id"].to_s == grader_step.details.to_h["source_snapshot_id"].to_s

        Output.new(
          attachment:,
          artifact: metadata["artifact"],
          format: metadata["format"],
          grader_name: metadata["grader_name"],
          workspace_path: metadata["workspace_path"],
          run_id: latest_run.id
        )
      end
    end.sort_by { |output| [ output.artifact.to_s, output.grader_name.to_s, output.run_id ] }
  end

  private

  def selected_steps
    collect = @workflow.steps.where(kind: "grader_collect", state: "succeeded").order(:position, :id).last
    return [] unless collect

    candidates = @workflow.steps.where(kind: "grader").to_a
    current = collect.loop_id.present? ? candidates.select { |candidate| candidate.loop_id == collect.loop_id && candidate.iteration == collect.iteration } : candidates

    carried = Array(@workflow.artifact(Steps::GraderFanout::CARRIED_FORWARD_ARTIFACT_KEY)).filter_map do |entry|
      candidates.detect do |candidate|
        candidate.iteration == entry["source_iteration"] && candidate.details.to_h["name"] == entry["name"]
      end
    end

    (current + carried).uniq(&:id).select(&:succeeded?)
  end

  def latest_successful_runs_by_step_id(steps)
    Run.where(step_id: steps.map(&:id), state: "succeeded")
       .order(created_at: :desc, id: :desc)
       .each_with_object({}) { |run, memo| memo[run.step_id] ||= run }
  end

  def coverage_attachments_by_run_id(runs)
    ActiveStorage::Attachment.where(record_type: "Run", record_id: runs.map(&:id), name: "coverage_outputs")
                             .includes(:blob)
                             .group_by(&:record_id)
  end
end
