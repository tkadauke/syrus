module Steps
  # Shared helpers for the Epic merge-train steps. The MergeTrain row is
  # created by the dispatcher (LandingQueueProcessor) and referenced from
  # the Workflow's artifacts under "merge_train_id".
  module MergeTrainStep
    private

    def merge_train
      @merge_train ||= begin
        id = workflow.artifact("merge_train_id")
        raise Base::StepFailed, "merge_train: workflow has no merge_train_id artifact" if id.blank?

        train = MergeTrain.find_by(id: id) ||
          raise(Base::StepFailed, "merge_train: MergeTrain ##{id} not found")
        if train.terminal?
          raise Base::StepFailed, "merge_train: MergeTrain ##{id} is #{train.state}; rebuild required"
        end

        train
      end
    end

    def epic
      merge_train.epic
    end

    def checkout_integration_branch!(git, train, chdir:, context:)
      raise Base::StepFailed, "#{context}: integration branch is missing; rebuild required" if train.integration_branch.blank?

      if train.integration_sha.present?
        git.run("checkout", "-B", train.integration_branch, train.integration_sha, chdir: chdir)
      else
        git.run("checkout", train.integration_branch, chdir: chdir)
      end
    rescue GitRunner::GitError => e
      raise Base::StepFailed,
            "#{context}: built integration branch #{train.integration_branch} " \
            "at #{train.integration_sha.presence || 'unknown SHA'} is unavailable; rebuild required (#{e.message})"
    end

    def current_git_branch(git, chdir)
      git.run("rev-parse", "--abbrev-ref", "HEAD", chdir: chdir).to_s.strip
    rescue GitRunner::GitError
      nil
    end

    def local_branch_sha(git, branch, chdir)
      git.run("rev-parse", "--verify", "refs/heads/#{branch}", chdir: chdir).to_s.strip.presence
    rescue GitRunner::GitError
      nil
    end

    def ensure_integration_branch_ref_at_head!(git, train, chdir:, context:)
      branch = train.integration_branch.to_s
      raise Base::StepFailed, "#{context}: integration branch is missing; rebuild required" if branch.blank?

      head_sha = git.run("rev-parse", "HEAD", chdir: chdir).to_s.strip
      branch_sha = local_branch_sha(git, branch, chdir)
      return head_sha if branch_sha == head_sha

      current_branch = current_git_branch(git, chdir)
      if current_branch == branch || current_branch == "HEAD"
        git.run("checkout", "-B", branch, head_sha, chdir: chdir)
        return head_sha
      end

      raise Base::StepFailed,
            "#{context}: checkout is on #{current_branch.presence || 'unknown branch'}, " \
            "not integration branch #{branch}; rebuild required"
    rescue GitRunner::GitError => e
      raise Base::StepFailed,
            "#{context}: could not update integration branch #{train.integration_branch}: #{e.message}"
    end

    # LandedCommit attribution target for train-level (not per-member)
    # commits: the Epic for an Epic-backed train, the MergeTrain itself for a
    # bundle-backed train (there's no Epic to attach to). nil is unreachable
    # in practice -- MergeTrain validates it is always exactly one of the two.
    def landed_commit_landable(train)
      return train.epic if train.epic_backed?
      return train if train.bundle_backed?

      nil
    end
  end
end
