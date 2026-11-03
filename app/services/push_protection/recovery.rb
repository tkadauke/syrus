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
    Outcome = Data.define(:kind, :detail, :candidate, :violations) do
      def initialize(kind:, detail:, candidate: nil, violations: [])
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

    def handle_rejection!(error, remote_tip: nil)
      sha = repo.head
      ref = error.ref.presence || "refs/heads/#{branch}"
      policy = RefPolicy.for(ref: ref, job: workflow.job)

      return quarantine!(error, sha, ref) unless policy.repairable?
      return stop!(error, sha, ref, Ledger::OPERATOR_REVIEW, "push protection rejected #{sha.first(12)} again; an identical SHA is never retried") if ledger.rejected?(sha)
      return stop!(error, sha, ref, Ledger::OPERATOR_REVIEW, "push-protection repair exhausted #{Ledger::MAX_REPAIR_ATTEMPTS} attempts") if ledger.attempts_exhausted?

      anchor = resolve_anchor(remote_tip)
      return stop!(error, sha, ref, Ledger::OPERATOR_REVIEW, "no GitHub-accepted clean anchor could be determined") if anchor.blank?
      return stop!(error, sha, ref, Ledger::UPSTREAM, upstream_message(error, anchor)) if upstream_contaminated?(error, anchor, sha)

      candidate = Candidate.new(repo: repo, branch: branch, anchor: anchor, bundle_dir: bundle_dir).prepare!
      ledger.record_rejection!(
        sha: candidate.rejected_head, findings: error.findings, ref: ref, status: Ledger::REPAIRING,
        extra: {
          "clean_anchor" => anchor, "candidate_sha" => candidate.sha, "rejected_range" => candidate.rejected_range,
          "rejected_bundle" => candidate.bundle_path, "baseline" => candidate.baseline,
          "metadata" => candidate.metadata, "allowed_paths" => allowed_paths_for(error, anchor, candidate)
        }
      )
      Outcome.new(kind: :repair, detail: error.message, candidate: candidate)
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
        return Outcome.new(kind: :operator_review, detail: "repair contract violated after #{ledger.attempts} attempts", violations: violations)
      end
      Outcome.new(kind: :contract_violation, detail: "repair contract violated", violations: violations)
    end

    # Undo everything a contract-violating attempt did: back to the candidate
    # commit with refs, remotes and repository config as at preparation time.
    def restore_candidate!
      data = ledger.data
      baseline = data["baseline"]
      repo.run("rebase", "--abort") rescue nil
      repo.run("merge", "--abort") rescue nil
      repo.run("reset", "--hard", data["candidate_sha"])
      repo.run("clean", "-fd")
      File.write(File.join(repo.path, ".git", "config"), baseline["config"])
      repo.restore_metadata(bundle_dir.join("git-metadata").to_s)
      wanted = baseline["refs"].to_h { |l| l.split(" ", 2).reverse }
      repo.refs_except(branch).each do |line|
        sha, name = line.split(" ", 2)
        repo.run("update-ref", "-d", name) unless wanted.key?(name)
        repo.run("update-ref", name, wanted[name]) if wanted.key?(name) && wanted[name] != sha
      end
      wanted.each { |name, sha| repo.run("update-ref", name, sha) unless repo.refs_except(branch).include?("#{sha} #{name}") }
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

    # GitHub normally names the files; when it does not, the repair may touch
    # any file the rejected range itself changed (never anything outside it).
    def allowed_paths_for(error, anchor, candidate)
      error.finding_paths.presence || repo.changed_paths(anchor, candidate.sha)
    end

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
      Outcome.new(kind: :verified, detail: "reconstructed #{sha}")
    end

    def quarantine!(error, sha, ref)
      ledger.record_rejection!(
        sha: sha, findings: error.findings, ref: ref, status: Ledger::QUARANTINED,
        extra: { "route_to_job_ids" => originating_job_ids, "reason" => "shared or synthesized ref; not rewritten directly" }
      )
      route_to_originating_jobs!(error, ref)
      Outcome.new(kind: :quarantine, detail: "#{ref} is a shared/synthesized ref; routed to originating Job(s) #{originating_job_ids.join(', ').presence || 'unknown'}")
    end

    def stop!(error, sha, ref, status, message)
      ledger.record_rejection!(sha: sha, findings: error.findings, ref: ref, status: status, extra: { "reason" => message })
      Outcome.new(kind: status.to_sym, detail: message)
    end

    # Jobs whose commits fed a shared/synthesized ref: for a merge train, its
    # member Jobs; otherwise the current Job.
    def originating_job_ids
      train = MergeTrain.find_by(integration_branch: branch)
      ids = train ? train.jobs.pluck(:id) : []
      ids.presence || [ workflow.job_id ]
    end

    # Hands the sanitized evidence to each originating Job (its newest workflow)
    # so remediation happens where the commits came from, not on shared history.
    def route_to_originating_jobs!(error, ref)
      originating_job_ids.each do |job_id|
        target = Workflow.where(job_id: job_id).reorder(id: :desc).first
        next if target.nil? || target.id == workflow.id

        Ledger.for(target).update!(
          "status" => Ledger::QUARANTINED, "quarantined_ref" => ref, "routed_from_workflow_id" => workflow.id,
          "evidence" => { "findings" => error.findings.map(&:to_h), "detected_at" => Time.current.iso8601 }
        )
      end
    end

    # Last commit GitHub is known to have accepted for this Job, strongest
    # evidence first: the ledger anchor (advanced only after accepted pushes),
    # then the branch tip GitHub reported live (a push to it was rejected, so the
    # tip is by definition accepted), then the merge-base with the default
    # branch (default-branch history was accepted upstream). A stale
    # remote-tracking ref is deliberately never used.
    def resolve_anchor(remote_tip)
      [ ledger.clean_anchor, remote_tip, default_branch_base ].each do |candidate|
        next if candidate.blank?
        return candidate if repo.commit_exists?(candidate) && repo.ancestor?(candidate, "HEAD")
      end
      nil
    end

    def default_branch_base
      repo.out("merge-base", "HEAD", "refs/remotes/origin/#{workflow.job.base_default_branch}")
    rescue GitRunner::GitError
      nil
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
