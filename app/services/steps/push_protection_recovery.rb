module Steps
  # Workflow-owned recovery for a GitHub push-protection rejection raised by the
  # shared authenticated push boundary. Included by Steps::Base.
  #
  # The rejecting step stays the owner: it prepares the single-commit candidate,
  # runs a bounded agentic repair in the same workspace (with one retry carrying
  # precise contract-violation feedback), has the harness reconstruct the
  # authoritative commit, republishes it through the caller's own push, and only
  # then lets the step continue. Anything that cannot be repaired in place stops
  # the step with a sanitized, evidence-carrying failure.
  module PushProtectionRecovery
    # `republish` pushes the (new) HEAD exactly as the caller's original push
    # did. Without it (shared/unsupported callers) the rejection is recorded and
    # the step fails for operator review.
    def handle_push_protection_rejection!(error, &republish)
      recovery = PushProtection::Recovery.for(workflow: workflow, workspace_path: workspace.path, branch: workspace.branch_name)
      outcome = recovery.handle_rejection!(error, remote_tip: push_protection_remote_tip)
      log("push protection: #{outcome.kind}: #{outcome.detail}", kind: "system")
      push_protection_fail!(error, outcome.kind, outcome.detail) unless outcome.repair? && republish

      repair_loop(recovery, error, outcome, &republish)
    end

    private

    def repair_loop(recovery, error, outcome)
      ledger = recovery.ledger
      violations = []
      loop do
        run_agent(prompt: Prompts::PushProtectionRepair.new(
          branch: workspace.branch_name, anchor: ledger.clean_anchor,
          findings: error.findings.map(&:to_h), violations: violations, attempt: ledger.attempts + 1
        ).to_s)
        amend_leftovers!
        result = recovery.verify_repair!
        break if result.kind == :verified

        push_protection_fail!(error, result.kind, "#{result.detail}: #{result.violations.join(' | ')}") if result.kind == :operator_review
        violations = result.violations
        log("push protection: repair contract violated (#{violations.size}); resetting to candidate and retrying", kind: "system")
        recovery.restore_candidate!
      end

      begin
        recovery.publish! { yield }
      rescue GithubPushProtection::Rejected => e
        push_protection_fail!(e, :operator_review, "GitHub still rejected the reconstructed commit")
      end
      log("push protection: repaired history published as #{head_sha.first(12)}", kind: "system")
      :repaired
    end

    # The agent may leave edits uncommitted; folding them into the single
    # candidate commit is exactly the permitted tip amend.
    def amend_leftovers!
      git = GitRunner.new
      return if git.run("status", "--porcelain", chdir: workspace.path.to_s).strip.empty?

      # Hooks are agent-writable and would run with harness credentials: never
      # execute them for harness-owned commands.
      git.run("-c", "core.hooksPath=/dev/null", "add", "-A", chdir: workspace.path.to_s)
      git.run("-c", "core.hooksPath=/dev/null", "commit", "--amend", "--no-edit", "--no-verify", chdir: workspace.path.to_s)
    end

    def push_protection_fail!(error, kind, message)
      fail_with!(:github_push_protection, "GitHub push protection rejected #{workspace.branch_name}: #{message}",
                 evidence: { "outcome" => kind.to_s, "findings" => error.findings.map(&:to_h) })
    end

    # GitHub is authoritative about what it accepted: the branch tip it holds now.
    def push_protection_remote_tip
      git = GitRunner.new
      env = { "GIT_TERMINAL_PROMPT" => "0" }
      out = authenticated_git("git_push_protection_ls_remote") do |url|
        git.run("ls-remote", url, "refs/heads/#{workspace.branch_name}", chdir: workspace.path.to_s, env: env)
      end
      sha = out.split.first
      return nil if sha.blank?

      fetch_push_protection_tip(git, sha, env)
      sha
    rescue GitRunner::GitError
      nil
    end

    def fetch_push_protection_tip(git, sha, env)
      git.run("cat-file", "-e", "#{sha}^{commit}", chdir: workspace.path.to_s)
    rescue GitRunner::GitError
      authenticated_git("git_push_protection_fetch_tip") { |url| git.run("fetch", url, sha, chdir: workspace.path.to_s, env: env) }
    end
  end
end
