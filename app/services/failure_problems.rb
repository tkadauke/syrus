# Declared Problems for failures whose structure is known where they happen.
#
# RunFailureClassifier reads free text -- agent output, diagnostics, recent
# job logs -- when nothing better is available, and that reading has been
# wrong in both directions: a deterministic native-extension build failure
# read as a transient provider blip because a backtrace frame said
# "Bundler::Settings#temporary", and a gem named `timeout` in a `bundle
# install` log read as a timed-out operation.
#
# The code that ran the command knows its exit status and has its output in
# hand, so it decides there, and declares the answer as a Problem code that
# the classifier returns before it reads any text. Each submodule parses one
# well-understood kind of output:
#
#   FailureProblems::Prepare    -- a dependency-install command's output tail
#   FailureProblems::Git        -- a GitRunner::GitError (command, exit, stderr)
#   FailureProblems::GithubApi  -- an Octokit error (HTTP status, class)
#
# Every function returns a Problem, or nil when the evidence is not specific
# enough to commit to an answer; nil means "fall back to inference", never
# "this is fine".
module FailureProblems
  module_function

  # The Problem an exception that escaped a step represents, when its
  # structure says so. Used by CaptureRunDiagnostic for exceptions that are
  # not StepFailed, and by StepFailed for its `cause` -- a step that rescues a
  # GitError or an Octokit error and re-raises it as a generic StepFailed
  # still declares what the underlying failure was.
  #
  # Wrappers that are not StepFailed (ImmutableSourceCheckout's
  # InfrastructureStateError wraps the GitError of a failed snapshot fetch)
  # are looked through to their cause, a few levels deep at most.
  MAX_CAUSE_DEPTH = 3

  def for_exception(exception, depth: 0)
    return nil if exception.nil? || depth > MAX_CAUSE_DEPTH

    case exception
    when GitRunner::GitError then Git.for(exception)
    when Octokit::Error then GithubApi.for(exception)
    else for_exception(exception.cause, depth: depth + 1)
    end
  rescue StandardError => e
    # Describing a failure must never become a second failure.
    Rails.logger.warn("[FailureProblems] could not describe #{exception.class}: #{e.class}: #{e.message}")
    nil
  end

  def declare(code, evidence = {})
    Problem.resolve(code, evidence: evidence.compact)
  end
end
