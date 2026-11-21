# Operator feedback on a Job whose implementation is blocked because its agent
# reported it cannot proceed -- the case where the feedback is usually the way
# out ("drop that requirement", "use this other approach").
#
# Ordinary chat feedback needs an implemented branch and becomes a chat_feedback
# workflow; on a running Job it is queued until the current run finishes. A
# blocked implementation never finishes, so that feedback waited forever. Here
# the feedback instead starts a fresh implementation attempt carrying it as
# operator context -- the same retry the Job page's "Retry implementation"
# runs -- which also retires the blocked workflow.
module BlockedImplementationFeedback
  module_function

  def applicable?(job)
    return false unless job.running? || job.queued?

    mode(job, feedback: nil).agent_blocked?
  end

  def retry!(job, feedback:)
    implementation = mode(job, feedback:)
    preflight = implementation.preflight
    raise ArgumentError, preflight.message unless preflight.eligible?

    result = implementation.execute
    raise ArgumentError, result.error unless result.success?

    result.workflow
  end

  def mode(job, feedback:)
    RetryJobs::Modes::Implementation.new(
      job: job,
      retry_context: feedback && "Operator feedback on the blocked implementation:\n\n#{feedback}",
      explicit_operator_intent: true
    )
  end
end
