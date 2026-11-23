# Narrow re-validation after an *agentic* rebase during landing.
#
# A clean rebase already carries the landing validation forward when the
# repository trusts it (Repository#trust_clean_rebase_grade). A rebase the
# agent had to resolve used to force a full re-validation, which costs a whole
# grader round even when the agent touched a single file. This records exactly
# which files the agent's resolution changed compared with the mechanical
# result of the same rebase, and decides which graders those files reach:
# graders whose scope covers a touched file run again, every other grader's
# passing result is carried forward from the prior landing validation.
#
# Same trust gate as the clean-rebase path: nothing is recorded, and nothing
# is carried, unless the repository has trust_clean_rebase_grade enabled.
class LandingAgenticRebase
  ARTIFACT_KEY = "landing_agentic_rebase".freeze
  DECISIONS_ARTIFACT_KEY = "landing_agentic_rebase_carry_forward".freeze
  OBJECT_ID_PATTERN = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/.freeze

  Partition = Data.define(:carried, :rerun)

  class << self
    # Files whose content in the agent-resolved HEAD differs from the
    # mechanical three-way merge of the moved base and the pre-rebase head.
    # Conflicted files carry conflict markers in the mechanical tree, so any
    # file the agent had to resolve differs by construction; so does any file
    # the agent edited beyond the conflicts. Returns nil when it cannot be
    # determined, which callers treat as "unknown": full re-validation.
    def touched_files(git:, chdir:, base_sha:, pre_head_sha:, head_ref: "HEAD")
      return nil if base_sha.blank? || pre_head_sha.blank?

      mechanical_tree = mechanical_tree(git, chdir, base_sha, pre_head_sha)
      return nil if mechanical_tree.blank?

      final_tree = git.run("rev-parse", "#{head_ref}^{tree}", chdir: chdir).to_s.strip
      return nil unless final_tree.match?(OBJECT_ID_PATTERN)

      git.run("diff", "--name-only", "--no-renames", mechanical_tree, final_tree, chdir: chdir)
        .split("\n").map(&:strip).reject(&:empty?).uniq.sort
    rescue GitRunner::GitError
      nil
    end

    def record!(workflow:, head_sha:, base_sha:, base_ref:, pre_head_sha:, touched_files:)
      workflow.set_artifact!(
        ARTIFACT_KEY,
        {
          "head_sha" => head_sha.to_s,
          "base_sha" => base_sha.to_s.presence,
          "base_ref" => base_ref.to_s.presence,
          "pre_head_sha" => pre_head_sha.to_s,
          "touched_files" => Array(touched_files).map(&:to_s).sort,
          "recorded_at" => Time.current.iso8601
        }.compact
      )
    end

    # The record describing exactly this head, from this workflow or, for a
    # rebase that ran as its own workflow, from any other workflow of the Job.
    # A record for any other head never applies.
    def recorded_for(workflow:, job:, head_sha:)
      return nil if head_sha.blank?

      workflows = [ workflow ]
      workflows.concat(job.workflows.includes(:workflow_artifact_values).reorder(id: :desc).to_a) if job
      workflows.each do |candidate|
        record = candidate.artifact(ARTIFACT_KEY)
        return record if record.is_a?(Hash) && record["head_sha"] == head_sha.to_s
      end
      nil
    end

    # Splits `graders` (the ones selected for this fanout) into those whose
    # prior passing result stays valid and those that must run again.
    #
    # A grader is carried only when the prior landing validation recorded a
    # conclusive, evidenced pass for its target, its command and environment
    # fingerprints are unchanged, and no touched file falls inside its scope
    # (own source scope, or a dependency's, per TargetGraph#affected). A
    # repo-wide grader has no scope to exclude a file from, so any touched file
    # reaches it. Anything unproven re-runs; this never widens what is trusted.
    def partition(graders:, touched_files:, manifest:, target_graph:, label_for:, fingerprints_for:)
      touched = Array(touched_files)
      evidence = Array(manifest.is_a?(Hash) ? manifest["targets"] : nil).index_by { |target| target["target_label"] }
      carried = []
      rerun = []

      graders.each do |grader|
        label = label_for.call(grader)
        reason = rerun_reason(grader, label, evidence[label], touched, target_graph, fingerprints_for.call(grader))
        if reason
          rerun << [ grader, reason ]
        else
          carried << [ grader, carry_reason(label, target_graph, touched) ]
        end
      end

      Partition.new(carried, rerun)
    end

    private

    def mechanical_tree(git, chdir, base_sha, pre_head_sha)
      output = begin
        git.run("merge-tree", "--write-tree", "--no-messages", base_sha, pre_head_sha, chdir: chdir)
      rescue GitRunner::GitError => e
        # Exit status 1 is "merged with conflicts": the tree is still written
        # (with conflict markers) and is the mechanical result to compare to.
        raise unless e.exit_status == 1

        e.output
      end
      output.to_s.lines.map(&:strip).find { |line| line.match?(OBJECT_ID_PATTERN) }
    end

    def rerun_reason(grader, label, prior, touched, target_graph, fingerprints)
      return "target is optional; only required targets are carried forward" unless grader.required
      return "no prior landing validation evidence for #{label}" unless prior
      return "prior result for #{label} was #{prior["outcome"]}, not passed" unless prior["outcome"] == GraderOutcome::PASSED
      return "prior result for #{label} has no recorded command/environment evidence" unless prior["has_evidence"]
      return "always_rerun is set on #{grader.name}" if grader.metadata["always_rerun"] == true

      current = fingerprints.to_h
      %w[command_fingerprint environment_fingerprint].each do |key|
        value = current[key].presence || current[key.to_sym].presence
        return "#{key.tr('_', ' ')} changed or unavailable" if value.blank? || value != prior[key]
      end

      return nil if touched.empty?

      selection = target_graph.affected(label, changed_files: touched)
      "agent-touched files reach #{label}: #{selection.reason}" if selection.affected
    end

    def carry_reason(label, target_graph, touched)
      return "agentic rebase changed no file beyond the mechanical rebase" if touched.empty?

      "agentic rebase touched #{touched.size} file(s), none inside #{label}'s scope"
    end
  end
end
