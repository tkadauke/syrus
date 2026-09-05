module Jobs
  # One-off, resumable repair for MergeTrainMember rows wrongly left
  # `failed` by the Steps::MergeTrainLand bug where a missing local git
  # object ("fatal: Not a valid commit name ...") was indistinguishable
  # from a genuine "commit is not reachable" and so failed every member of
  # an otherwise successfully landed train (production evidence: train
  # 5067 / JOB-4299 / PR #3193, from WF-25752 landing Epic #306 via
  # integration PR #3231). See Steps::MergeTrainLand#ancestor_of_integration
  # and #trust_recent_build_evidence? for the forward-looking fix; this is
  # the backward-looking repair for rows the bug already produced.
  #
  # Scoped to trains whose *train-level* landing already reached `state:
  # "succeeded"` with a recorded `integration_sha` -- Steps::MergeTrainLand
  # only sets that after GitHub actually reported the integration PR merged,
  # so it is independent, positive evidence the integration PR genuinely
  # merged regardless of what happened to any individual member's
  # reconciliation. For each MergeTrainMember still `failed` under such a
  # train, this only repairs the member when its Job has its own recorded
  # "implementation" LandedCommit from that train's build step -- never
  # blindly closes every failed member, only ones with real per-member
  # landing evidence.
  #
  # Idempotent / resumable: already-closed Jobs and already-merged members
  # are skipped, so re-running after a partial failure is safe.
  class MergeTrainMemberReconciliationRepair
    Result = Struct.new(:checked, :repaired, :skipped, :errors, keyword_init: true)

    def initialize(repository: nil, logger: Rails.logger)
      @repository = repository
      @logger = logger
    end

    def call(train_ids: nil, dry_run: false)
      result = Result.new(checked: 0, repaired: 0, skipped: 0, errors: 0)

      trains_scope(train_ids).find_each do |train|
        repair_train!(train, dry_run: dry_run, result: result)
      end

      result
    end

    private

    attr_reader :repository, :logger

    def trains_scope(train_ids)
      scope = MergeTrain.where(state: "succeeded")
      scope = scope.where(repository: repository) if repository
      scope = scope.where(id: train_ids) if train_ids.present?
      scope
    end

    def repair_train!(train, dry_run:, result:)
      integration_sha = train.integration_sha.presence
      return if integration_sha.blank?

      train.members.includes(:job).where(state: "failed").find_each do |member|
        result.checked += 1
        repair_member!(train, member, integration_sha, dry_run: dry_run, result: result)
      end
    end

    def repair_member!(train, member, integration_sha, dry_run:, result:)
      job = member.job

      if job.closed?
        result.skipped += 1
        logger.info("[MergeTrainMemberReconciliationRepair] skip #{job.slug}: already closed")
        return
      end

      unless LandedCommit.where(landable: job, kind: "implementation").exists?
        result.skipped += 1
        logger.info(
          "[MergeTrainMemberReconciliationRepair] skip #{job.slug}: no recorded implementation " \
          "commit for train ##{train.id}; leaving failed for operator review"
        )
        return
      end

      logger.info("[MergeTrainMemberReconciliationRepair] #{dry_run ? "would repair" : "repairing"} #{job.slug} for train ##{train.id}")
      repair_records!(job, member, integration_sha) unless dry_run
      result.repaired += 1
    rescue StandardError => e
      result.errors += 1
      logger.warn("[MergeTrainMemberReconciliationRepair] failed #{job.slug} for train ##{train.id}: #{e.class}: #{e.message}")
    end

    def repair_records!(job, member, integration_sha)
      ActiveRecord::Base.transaction do
        job.update_column(:landed_sha, integration_sha)
        job.close_with_reason!("pr_merged") if job.may_close?
        member.update!(state: "merged", reason: nil)
      end
    end
  end
end
