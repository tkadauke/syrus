# Operator feedback on a Job whose current work is blocked because its agent
# reported it cannot proceed -- the case where the feedback is usually the way
# out ("drop that requirement", "use this other approach").
#
# Ordinary chat feedback on a running Job is queued until the current run
# finishes, and a blocked run never finishes, so that feedback waited forever.
# Here it is delivered instead, in the shape the blocked work needs:
#
# - A blocked *implementation* starts a fresh implementation attempt carrying
#   the feedback as operator context -- the same retry the Job page's "Retry
#   implementation" runs -- which also retires the blocked workflow.
# - Any other blocked workflow -- chat or PR feedback, a CI repair -- already
#   sits on an implemented branch. Retrying implementation
#   would start over from the base and abandon that branch, so the blocked
#   workflow is retired and the feedback runs as an ordinary chat_feedback
#   workflow on the existing branch (formal/SyrusModel/BlockedFeedback.lean).
module BlockedImplementationFeedback
  RETIRED_REASON = "retired_for_operator_feedback".freeze

  module_function

  def applicable?(job)
    blocked_workflow(job).present?
  end

  def retry!(job, feedback:)
    workflow = blocked_workflow(job)
    raise ArgumentError, "#{job.slug} has no blocked work for this feedback to unblock" unless workflow

    on_implemented_branch?(job, workflow) ? resubmit_feedback!(job, workflow, feedback:) : retry_implementation!(job, feedback:)
  end

  def blocked_workflow(job)
    return nil unless job.running? || job.queued?

    workflow = job.latest_workflow
    return nil unless workflow&.blocked? && workflow.artifact("cannot_proceed").present?
    return nil if workflow.landing_workflow? || Workflow::TriggerKind.non_approval_blocking?(workflow.trigger_kind)

    workflow
  end

  # Feedback workflows always run on the implemented branch; any other kind
  # that does not build from the base does too once the Job has a branch.
  def on_implemented_branch?(job, workflow)
    return true if Workflow::TriggerKind.feedback_kind_for(workflow.trigger_kind).present?
    return false if Workflow::TriggerKind.builds_from_base?(workflow.trigger_kind)

    job.branch_name.present?
  end

  def retry_implementation!(job, feedback:)
    implementation = RetryJobs::Modes::Implementation.new(
      job: job,
      retry_context: "Operator feedback on the blocked implementation:\n\n#{feedback}",
      explicit_operator_intent: true
    )
    preflight = implementation.preflight
    raise ArgumentError, preflight.message unless preflight.eligible?

    result = implementation.execute
    raise ArgumentError, result.error unless result.success?

    result.workflow
  end

  def resubmit_feedback!(job, workflow, feedback:)
    WorkUnits::WorkflowCancellation.cancel!(
      workflow, reason: RETIRED_REASON, artifacts: { "cancelled_reason" => RETIRED_REASON }
    )
    job.reload.clear_needs_attention!(reason: "agent_cannot_proceed")
    job.reload

    result = ChatFeedbackSubmission.call(job: job, feedback: feedback, allowed_states: [ job.state ])
    raise ArgumentError, result.error unless result.success?

    result.workflow
  end
end
