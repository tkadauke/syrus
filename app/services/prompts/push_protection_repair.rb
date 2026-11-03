module Prompts
  # Instructions for the bounded agentic repair of a GitHub push-protection
  # rejection. Only sanitized evidence (secret type, path, line) is included --
  # never secret material or GitHub's bypass URL.
  class PushProtectionRepair
    include GithubContentTrust

    def initialize(branch:, anchor:, findings:, violations: [], attempt: 1, max_attempts: PushProtection::Ledger::MAX_REPAIR_ATTEMPTS)
      @branch = branch
      @anchor = anchor
      @findings = findings
      @violations = violations
      @attempt = attempt
      @max_attempts = max_attempts
    end

    def to_s
      [ github_content_trust_boundary, body, feedback, ShellCommandExecutionContract::TEXT ].compact.join("\n\n---\n\n")
    end

    private

    def body
      <<~TEXT
        GitHub push protection rejected a push of branch `#{@branch}` because it detected secrets.
        Syrus has already collapsed the rejected commits into ONE commit directly on top of the
        clean anchor `#{@anchor}` (repair attempt #{@attempt} of #{@max_attempts}).

        Findings reported by GitHub (sanitized):
        #{findings_list}

        Your only job is the semantic content repair:
        - Remove or replace each flagged secret in the listed files (use a placeholder, an
          environment variable, or a credentials lookup that fits the code). Treat the secret as
          compromised; do not copy it anywhere.
        - Keep the change minimal. Edit only the files listed above.

        Hard rules (validated by repository topology afterwards, not by what you ran):
        - Do NOT push, fetch, or touch any remote.
        - Leave exactly one commit directly atop `#{@anchor}`. Amending the tip commit
          (`git add -A && git commit --amend --no-edit`) is allowed and encouraged.
        - Do NOT rebase, merge, cherry-pick, reset to another commit, or create/move/delete any
          branch, tag or other ref.
        - Do NOT change git remotes, git configuration, submodules, or any unrelated file.
        - Do not try to bypass or "allow" the secret through GitHub.
      TEXT
    end

    def findings_list
      return "- (GitHub did not report locations)" if @findings.empty?

      @findings.map { |f| "- #{f['secret_type'] || 'secret'} in #{f['path'] || 'unknown path'}#{":#{f['line']}" if f['line']}" }.join("\n")
    end

    def feedback
      return nil if @violations.empty?

      "Your previous attempt violated the repair contract; the workspace was reset to the candidate. Fix exactly these:\n" +
        @violations.map { |v| "- #{v}" }.join("\n")
    end
  end
end
