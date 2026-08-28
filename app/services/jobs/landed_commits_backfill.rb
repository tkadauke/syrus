module Jobs
  # One-off, resumable backfill of LandedCommit rows (JOB-3749) for landings
  # that happened before the forward-capture Jobs (JOB-3750/3751 and the
  # bundle-support follow-up) shipped, so GitHistory::CommitAttributor's
  # legacy Job#landed_sha-only fallback stops being needed for old history.
  # Mirrors, against history instead of a live landing:
  #   Steps::AutoMerge#record_landed_commits
  #   Steps::MergeTrainBuild#record_member_commits!
  #   Steps::MergeTrainReconcile#record_reconcile_commit!
  #   Steps::MergeTrainLand#record_integration_merge_commit!
  #
  # Deliberately avoids author/committer identity (a period of PAT-fallback
  # credential mode means Syrus-authored commits can be indistinguishable
  # from a genuine manual push by the operator) and avoids git-log
  # mainline-checkpoint ordering (ambiguous if a real external commit landed
  # between two Syrus landings). Instead:
  #   - Regular Job: the original PR commit count N (from the GitHub API)
  #     plus `git log --first-parent -n N` on `landed_sha` gives the exact,
  #     self-contained range.
  #   - Merge-train / job-bundle landing: the merge commit's own two parents
  #     bound the exact range for free; per-member attribution comes from
  #     subject-matching each member's original PR commits against that
  #     range, walked in MergeTrainMember#position order. Anything left over
  #     is the (at most one) merge_train_reconcile commit.
  #
  # Scoped to a single repository per invocation (live GitHub API calls per
  # historical Job/PR). Resumable: skips any Job/landing that already has
  # LandedCommit rows. A pr_commits/compare failure or a git-history mismatch
  # for one Job/landing is logged and skipped rather than aborting the run.
  class LandedCommitsBackfill
    Result = Struct.new(:checked, :recorded, :commits_recorded, :skipped, :errors, keyword_init: true)

    SOFT_FAIL_ERRORS = [ Octokit::Error, GitRunner::GitError, ArgumentError ].freeze

    def initialize(repository:, user: nil, client_factory: nil, git: nil, bare_clone: nil, logger: Rails.logger)
      @repository = repository
      @user = user
      @client_factory = client_factory || ->(job) { GithubClient.for(repository: job.repository, user: job.user) }
      @git = git || GitRunner.new
      @bare_clone = bare_clone || RepositoryBareClone.new(repository, git: @git)
      @logger = logger
    end

    def call(dry_run: false)
      result = Result.new(checked: 0, recorded: 0, commits_recorded: 0, skipped: 0, errors: 0)

      sync_bare_clone!
      backfill_regular_jobs!(result, dry_run: dry_run)
      backfill_merge_trains!(result, dry_run: dry_run)

      result
    end

    private

    attr_reader :repository, :client_factory, :git, :bare_clone, :logger

    def sync_bare_clone!
      bare_clone.sync!(user: representative_user)
    rescue StandardError => e
      logger.warn("[LandedCommitsBackfill] could not sync bare clone for #{repository.slug}: #{e.class}: #{e.message}")
    end

    def representative_user
      @user ||= repository.jobs.where.not(user_id: nil).order(:created_at).first&.user || repository.user
    end

    # --- Regular Jobs -----------------------------------------------------

    def backfill_regular_jobs!(result, dry_run:)
      regular_jobs_scope.find_each do |job|
        result.checked += 1

        if LandedCommit.exists?(landable_type: "Job", landable_id: job.id)
          result.skipped += 1
          logger.info("[LandedCommitsBackfill] skip #{job.slug}: already recorded")
          next
        end

        begin
          record_regular_job!(job, dry_run: dry_run, result: result)
        rescue *SOFT_FAIL_ERRORS => e
          result.errors += 1
          logger.warn("[LandedCommitsBackfill] failed #{job.slug}: #{e.class}: #{e.message}")
        end
      end
    end

    def regular_jobs_scope
      repository.jobs
        .where.not(landed_sha: nil)
        .where.not(kind: "external_pr")
        .where.not(id: MergeTrainMember.select(:job_id))
    end

    def record_regular_job!(job, dry_run:, result:)
      raise ArgumentError, "#{job.slug} has no pr_number" if job.pr_number.blank?

      count = client_for(job).pr_commits(repository.slug, job.pr_number).size
      if count.zero?
        result.skipped += 1
        logger.info("[LandedCommitsBackfill] skip #{job.slug}: PR ##{job.pr_number} has no commits")
        return
      end

      shas = first_parent_shas(job.landed_sha, count)
      if shas.size != count
        raise ArgumentError, "expected #{count} commit(s) ending at #{job.landed_sha}, found #{shas.size}"
      end

      write_landed_commits!(job, shas, kind: "implementation") unless dry_run
      result.recorded += 1
      result.commits_recorded += shas.size
      logger.info("[LandedCommitsBackfill] #{dry_run ? "would record" : "recorded"} #{shas.size} commit(s) for #{job.slug}")
    end

    # --- Merge-train / job-bundle landings ---------------------------------

    def backfill_merge_trains!(result, dry_run:)
      merge_train_scope.find_each do |train|
        result.checked += 1

        if train_already_recorded?(train)
          result.skipped += 1
          logger.info("[LandedCommitsBackfill] skip merge-train ##{train.id}: already recorded")
          next
        end

        begin
          record_merge_train!(train, dry_run: dry_run, result: result)
        rescue *SOFT_FAIL_ERRORS => e
          result.errors += 1
          logger.warn("[LandedCommitsBackfill] failed merge-train ##{train.id}: #{e.class}: #{e.message}")
        end
      end
    end

    def merge_train_scope
      MergeTrain.where(repository: repository, state: "succeeded")
    end

    def train_already_recorded?(train)
      return true if train.integration_sha.present? && LandedCommit.exists?(sha: train.integration_sha)

      member_job_ids = train.members.pluck(:job_id)
      LandedCommit.exists?(landable_type: "Job", landable_id: member_job_ids)
    end

    def record_merge_train!(train, dry_run:, result:)
      sha = train.integration_sha
      raise ArgumentError, "merge-train ##{train.id} has no integration_sha" if sha.blank?

      parents = parent_shas(sha)
      unless parents.size == 2
        raise ArgumentError, "expected a two-parent merge commit at #{sha}, found #{parents.size} parent(s)"
      end

      base_parent, integration_parent = parents
      remaining = ranged_log(base_parent, integration_parent)
      landable = landed_commit_landable(train)
      total_commits = 0

      train.members.includes(:job).each do |member|
        subjects = pr_commit_subjects(member.job)
        taken = remaining.first(subjects.size)
        if taken.size != subjects.size || taken.map(&:last) != subjects
          raise ArgumentError, "commits for #{member.job.slug} did not match the integration range at #{sha}"
        end

        write_landed_commits!(member.job, taken.map(&:first), kind: "implementation") unless dry_run
        total_commits += taken.size
        remaining = remaining.drop(taken.size)
      end

      # At most one reconcile commit lands per train (commit_agent_changes
      # squashes the whole reconcile step into a single commit) — if several
      # entries are somehow left, the last one (closest to the integration
      # tip) is the true post-reconcile state.
      if remaining.present?
        write_landed_commits!(landable, [ remaining.last.first ], kind: "reconcile") unless dry_run
        total_commits += 1
      end

      write_landed_commits!(landable, [ sha ], kind: "integration_merge") unless dry_run
      total_commits += 1

      result.recorded += 1
      result.commits_recorded += total_commits
      logger.info(
        "[LandedCommitsBackfill] #{dry_run ? "would record" : "recorded"} merge-train ##{train.id} " \
        "(#{train.members.size} member(s)#{remaining.present? ? " + reconcile" : ""})"
      )
    end

    def landed_commit_landable(train)
      train.epic_backed? ? train.epic : train
    end

    # --- Git / GitHub plumbing ---------------------------------------------

    def client_for(job)
      client_factory.call(job)
    end

    def clone_path
      bare_clone.path
    end

    def first_parent_shas(sha, count)
      return [] if count.to_i <= 0

      output = git.run("log", "--first-parent", "--reverse", "-n", count.to_s, "--pretty=format:%H", sha, chdir: clone_path.to_s)
      output.to_s.split("\n").map(&:strip).reject(&:empty?)
    end

    def parent_shas(sha)
      output = git.run("log", "-1", "--pretty=format:%P", sha, chdir: clone_path.to_s)
      output.to_s.strip.split(" ")
    end

    # Oldest-first [sha, subject] pairs for every commit uniquely reachable
    # from head_sha but not base_sha.
    def ranged_log(base_sha, head_sha)
      output = git.run("log", "--reverse", "--pretty=format:%H%x1f%s", "#{base_sha}..#{head_sha}", chdir: clone_path.to_s)
      output.to_s.split("\n").reject(&:blank?).map { |line| line.split("\x1f", 2) }
    end

    def pr_commit_subjects(job)
      client_for(job).pr_commits(repository.slug, job.pr_number).map { |commit| commit_subject(commit) }
    end

    def commit_subject(commit)
      commit.commit&.message.to_s.lines.first.to_s.strip
    end

    def write_landed_commits!(landable, shas, kind:)
      shas.each_with_index do |sha, position|
        LandedCommit.create!(landable: landable, sha: sha, kind: kind, position: position)
      end
    end
  end
end
