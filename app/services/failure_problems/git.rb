module FailureProblems
  # Classifies one failed git command from its own output (GitRunner::GitError
  # carries the redacted command, exit status and merged stdout/stderr).
  #
  # Deterministic answers are checked first: a rejected push, a conflict, an
  # authentication refusal or a missing ref is a statement about the
  # repository or the request, and retrying it only repeats the answer. Only
  # then is the output read for transport noise (GitTransportErrors, which the
  # workspace clone fallback shares). A failure that matches neither returns
  # nil -- a git command failing for a reason its output does not name is
  # exactly the opaque case the classifier's inference is for.
  module Git
    module_function

    CONFLICT_PATTERN = /^CONFLICT \(|Merge conflict in |error: could not apply |\bneeds merge\b|unmerged files|Resolve all conflicts manually|after resolving the conflicts/i

    AUTH_PATTERN = /Authentication failed|could not read Username|Permission denied \(publickey\)|Permission to \S+ denied|remote: Permission denied|Repository not found|The requested URL returned error: 40[13]\b|Invalid username or (?:password|token)|terminal prompts disabled/i

    MISSING_REF_PATTERN = /couldn't find remote ref (\S+)|remote ref does not exist|fatal: invalid refspec '([^']+)'|unknown revision or path not in the working tree|fatal: bad revision '([^']+)'|fatal: Not a valid object name:? '?([^'\s]+)|fatal: ambiguous argument '([^']+)'|pathspec '([^']+)' did not match any file|Remote branch (\S+) not found|fatal: no such ref|src refspec (\S+) does not match any/i

    def for(error)
      output = error.output.to_s
      command = Array(error.command).join(" ")
      base = { git_command: command.truncate(200), exit_status: error.exit_status }

      return FailureProblems.declare(:branch_diverged, base.merge(push_rejected: true)) if push_rejected?(output)
      return FailureProblems.declare(:git_conflict, base) if output.match?(CONFLICT_PATTERN)
      return FailureProblems.declare(:git_auth_denied, base) if output.match?(AUTH_PATTERN)

      if (match = output.match(MISSING_REF_PATTERN))
        return FailureProblems.declare(:git_ref_missing, base.merge(ref: match.captures.compact.first))
      end

      if GitTransportErrors.transient?(output)
        return FailureProblems.declare(:git_transport_transient, base.merge(transport_error: transport_line(output)))
      end

      nil
    end

    # The same parenthesized rejection reasons Steps::Base#push_rejected?
    # reads: a lease or fast-forward refusal, never a server failure.
    def push_rejected?(output)
      output.match?(Steps::Base::PUSH_REJECTED_PATTERN)
    end

    def transport_line(output)
      output.lines.map(&:strip).find { |line| GitTransportErrors.transient?(line) }&.truncate(200)
    end
  end
end
