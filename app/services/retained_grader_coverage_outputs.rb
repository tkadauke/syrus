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
    selected_steps.flat_map do |grader_step|
      latest_run = grader_step.runs.where(state: "succeeded").order(created_at: :desc, id: :desc).first
      next [] unless latest_run

      latest_run.coverage_outputs.attachments.includes(:blob).filter_map do |attachment|
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

    current = if collect.loop_id.present?
      @workflow.steps.where(kind: "grader", loop_id: collect.loop_id, iteration: collect.iteration).to_a
    else
      @workflow.steps.where(kind: "grader").to_a
    end

    carried = Array(@workflow.artifact(Steps::GraderFanout::CARRIED_FORWARD_ARTIFACT_KEY)).filter_map do |entry|
      @workflow.steps.where(
        kind: "grader",
        iteration: entry["source_iteration"]
      ).detect { |candidate| candidate.details.to_h["name"] == entry["name"] }
    end

    (current + carried).uniq(&:id).select(&:succeeded?)
  end
end
