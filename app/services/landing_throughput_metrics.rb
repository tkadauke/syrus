class LandingThroughputMetrics
  ARTIFACT_KEY = "landing_throughput_metrics".freeze

  def self.record_validation_decision!(workflow:, decision:, context:, head_sha: nil, base_sha: nil)
    event = {
      "context" => context.to_s,
      "outcome" => decision.reusable? ? "skipped" : "rerun",
      "reason" => decision.reason,
      "match_type" => decision.match_type,
      "head_sha" => head_sha.to_s.presence,
      "base_sha" => base_sha.to_s.presence,
      "source_workflow_id" => decision.workflow&.id,
      "recorded_at" => Time.current.iso8601
    }.compact

    append!(workflow, "validation_decisions", event)
  end

  def self.record_grader_loop!(workflow:, iteration:, grader_count:, started_at:, finished_at:, wall_clock_s:, summed_duration_s:, failed_required_count:)
    event = {
      "iteration" => iteration,
      "grader_count" => grader_count,
      "started_at" => started_at&.iso8601,
      "finished_at" => finished_at&.iso8601,
      "wall_clock_s" => rounded(wall_clock_s),
      "summed_duration_s" => rounded(summed_duration_s),
      "failed_required_count" => failed_required_count,
      "outcome" => failed_required_count.to_i.positive? ? "failed" : "passed",
      "recorded_at" => Time.current.iso8601
    }.compact

    append!(workflow, "grader_loops", event)
  end

  def self.append!(workflow, key, event)
    current = workflow.artifact(ARTIFACT_KEY)
    current = {} unless current.is_a?(Hash)
    events = Array(current[key.to_s])
    workflow.set_artifact!(ARTIFACT_KEY, current.merge(key.to_s => events + [ event ]))
  end
  private_class_method :append!

  def self.rounded(value)
    return nil if value.nil?

    value.to_f.round(3)
  end
  private_class_method :rounded
end
