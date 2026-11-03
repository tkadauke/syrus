module PushProtection
  # Workflow-owned recovery protocol for a GithubPushProtection::Rejected.
  #
  #   handle_rejection!  classify ownership, record evidence, preserve the
  #                      rejected workspace outside GitHub, build the
  #                      single-commit candidate (or quarantine / stop)
  #   verify_repair!     validate the agent's result by topology; on success
  #                      reconstruct the authoritative commit
  #   publish!           push the reconstructed SHA via the caller's block,
  #                      advancing the clean anchor only after GitHub accepts
  #
  # Never retries an identical rejected SHA and never bypasses push protection.
  class Recovery
    Outcome = Data.define(:kind, :message, :candidate, :violations) do
      def initialize(kind:, message:, candidate: nil, violations: [])
        super
      end

      def repair? = kind == :repair
    end

    def self.for(workflow:, workspace_path:, branch:, git: GitRunner.new)
      new(workflow: workflow, workspace_path: workspace_path, branch: branch, git: git)
    end

    def initialize(workflow:, workspace_path:, branch:, git: GitRunner.new)
      @workflow = workflow
      @branch = branch
      @repo = Repo.new(workspace_path, git: git)
      @ledger = Ledger.for(workflow)
    end

    attr_reader :ledger

    def handle_rejection!(error)
      sha = repo.head
      ref = error.ref.presence || "refs/heads/#{branch}"
      policy = RefPolicy.for(ref: ref, job: workflow.job)

      return quarantine!(error, sha, ref) unless policy.repairable?
      return stop!(error, sha, ref, Ledger::OPERATOR_REVIEW, "push protection rejected #{sha.first(12)} again; an identical SHA is never retried") if ledger.rejected?(sha)
      return stop!(error, sha, ref, Ledger::OPERATOR_REVIEW, "push-protection repair exhausted #{Ledger::MAX_REPAIR_ATTEMPTS} attempts") if ledger.attempts_exhausted?

      anchor = resolve_anchor
      return stop!(error, sha, ref, Ledger::OPERATOR_REVIEW, "no GitHub-accepted clean anchor could be determined") if anchor.blank?
      return stop!(error, sha, ref, Ledger::UPSTREAM, upstream_message(error, anchor)) if upstream_contaminated?(error, anchor, sha)

      candidate = Candidate.new(repo: repo, branch: branch, anchor: anchor, bundle_dir: bundle_dir).prepare!
      ledger.record_rejection!(
        sha: candidate.rejected_head, findings: error.findings, ref: ref, status: Ledger::REPAIRING,
        extra: {
          "clean_anchor" => anchor, "candidate_sha" => candidate.sha, "rejected_range" => candidate.rejected_range,
          "rejected_bundle" => candidate.bundle_path, "baseline" => candidate.baseline,
          "metadata" => candidate.metadata, "allowed_paths" => error.finding_paths
        }
      )
      Outcome.new(kind: :repair, message: error.message, candidate: candidate)
    end

    # Returns an Outcome: :repair-contract-ok => kind :verified, otherwise the
    # violations to feed back to the agent (or operator review when exhausted).
    def verify_repair!
      data = ledger.data
      violations = TopologyValidator.new(
        repo: repo, branch: branch, anchor: data["clean_anchor"],
        rejected_shas: Array(data["rejected_shas"]) + Array(data["rejected_range"]),
        baseline: data["baseline"], allowed_paths: Array(data["allowed_paths"])
      ).violations
      return reconstruct!(data) if violations.empty?

      ledger.increment_attempts!(violations: violations)
      if ledger.attempts_exhausted?
        ledger.update!("status" => Ledger::OPERATOR_REVIEW)
        return Outcome.new(kind: :operator_review, message: "repair contract violated after #{ledger.attempts} attempts", violations: violations)
      end
      Outcome.new(kind: :contract_violation, message: "repair contract violated", violations: violations)
    end

    # Pushes the reconstructed commit. The block performs the real push (through
    # the caller's authenticated boundary). A repeat rejection never retries.
    def publish!
      sha = repo.head
      raise ArgumentError, "refusing to push rejected SHA #{sha}" if ledger.rejected?(sha)

      yield sha
      ledger.record_accepted!(sha)
      ledger.update!("status" => Ledger::RESOLVED, "published_sha" => sha)
      sha
    rescue GithubPushProtection::Rejected => e
      # GitHub still rejects the harness-reconstructed commit: the repair did
      # not remove the secret. Keep the evidence and require operator review.
      ledger.record_rejection!(sha: sha, findings: e.findings, ref: e.ref || "refs/heads/#{branch}",
                               status: Ledger::OPERATOR_REVIEW)
      raise
    end

    private

    attr_reader :workflow, :branch, :repo

    def reconstruct!(data)
      metadata = Metadata.from_h(data["metadata"])
      sha = Reconstructor.call(repo, anchor: data["clean_anchor"], metadata: metadata)
      leftover = TopologyValidator.new(
        repo: repo, branch: branch, anchor: data["clean_anchor"],
        rejected_shas: Array(data["rejected_shas"]) + Array(data["rejected_range"]),
        baseline: data["baseline"], allowed_paths: Array(data["allowed_paths"])
      ).violations
      raise "reconstructed commit failed topology validation: #{leftover.join('; ')}" if leftover.any?

      ledger.update!("reconstructed_sha" => sha)
      Outcome.new(kind: :verified, message: "reconstructed #{sha}")
    end

    def quarantine!(error, sha, ref)
      ledger.record_rejection!(
        sha: sha, findings: error.findings, ref: ref, status: Ledger::QUARANTINED,
        extra: { "route_to_job_ids" => originating_job_ids, "reason" => "shared or synthesized ref; not rewritten directly" }
      )
      Outcome.new(kind: :quarantine, message: "#{ref} is a shared/synthesized ref; routed to originating Job(s) #{originating_job_ids.join(', ').presence || 'unknown'}")
    end

    def stop!(error, sha, ref, status, message)
      ledger.record_rejection!(sha: sha, findings: error.findings, ref: ref, status: status, extra: { "reason" => message })
      Outcome.new(kind: status.to_sym, message: message)
    end

    def originating_job_ids
      [ workflow.job_id ]
    end

    # Last commit GitHub accepted: the ledger anchor, else the remote branch tip
    # known before this push, else the merge-base with the default branch.
    def resolve_anchor
      anchor = ledger.clean_anchor
      anchor ||= repo.out("rev-parse", "--verify", "refs/remotes/origin/#{branch}^{commit}") rescue nil
      anchor ||= repo.out("merge-base", "HEAD", "refs/remotes/origin/#{workflow.job.base_default_branch}") rescue nil
      return nil unless anchor.present? && repo.commit_exists?(anchor) && repo.ancestor?(anchor, "HEAD")

      anchor
    end

    # A finding whose commit is the anchor, an ancestor of it, or outside the
    # rejected range belongs to upstream/shared history, not this Job.
    def upstream_contaminated?(error, anchor, head)
      range = repo.range(anchor, head)
      error.commit_shas.any? do |prefix|
        full = repo.out("rev-parse", "--verify", "#{prefix}^{commit}") rescue nil
        full.nil? || range.exclude?(full)
      end
    end

    def upstream_message(error, anchor)
      "finding is present in the accepted anchor #{anchor.first(12)} or other upstream/shared history; remediate with its owner"
    end

    def bundle_dir
      WorkflowWorkspace.data_root.join("push_protection", workflow.id.to_s)
    end
  end
end
