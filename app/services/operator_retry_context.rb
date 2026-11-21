# Operator guidance a retry carries into an existing Workflow.
#
# Every implement run -- including the repair rounds of a grade loop --
# composes its prompt from the Workflow's `replay_context` artifact, under
# "Additional context from the operator". Appending to it before a failed-step
# retry or grade-loop restart is how an operator steers the next repair round
# on the current branch: the middle ground between restarting the loop with no
# new information and retrying implementation from the base, which discards
# the branch. It is the only steering a Job has before it reaches implemented,
# where chat feedback takes over.
module OperatorRetryContext
  ARTIFACT_KEY = "replay_context".freeze

  module_function

  # Appends `text` and returns the previous value, so a caller whose retry
  # does not start can put the artifact back.
  def append!(workflow, text, at: Time.current)
    text = text.to_s.strip
    previous = workflow.artifact(ARTIFACT_KEY)
    return previous if text.blank?

    entry = "Operator guidance (#{at.utc.iso8601}):\n#{text}"
    workflow.set_artifact!(ARTIFACT_KEY, [ previous.to_s.strip.presence, entry ].compact.join("\n\n"))
    previous
  end

  def restore!(workflow, previous)
    workflow.set_artifact!(ARTIFACT_KEY, previous)
  end

  # Wraps a retry: appends the guidance, runs the block, and restores the
  # artifact unless the block's result reports success.
  def with_context(workflow, text)
    return yield if text.to_s.strip.blank?

    previous = append!(workflow, text)
    result = yield
    restore!(workflow, previous) unless result.respond_to?(:success?) && result.success?
    result
  rescue StandardError
    restore!(workflow, previous) if defined?(previous)
    raise
  end
end
