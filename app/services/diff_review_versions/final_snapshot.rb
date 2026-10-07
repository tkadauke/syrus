module DiffReviewVersions
  class FinalSnapshot
    FINAL_SOURCE_KEY = "final_all_changes".freeze
    TRUSTED_STEP_KINDS = %w[implement respond].freeze
    Result = Data.define(:version, :status, :reason) do
      def materialized? = version.present?
    end

    def self.materialize(job:, user: nil, logger: Rails.logger)
      new(job: job, user: user, logger: logger).materialize
    end

    def initialize(job:, user:, logger:)
      @job = job
      @user = user || job&.user
      @logger = logger
      @repository = job&.repository
    end

    def materialize
      return skipped("missing_job") unless job
      return skipped("job_not_closed") unless job.closed?
      return skipped("missing_branch_name") if job.branch_name.blank?

      existing_final || from_live_branch || from_historical_run || skipped("no_trustworthy_diff")
    end

    private

    attr_reader :job, :user, :repository, :logger

    def existing_final
      version = job.diff_review_versions
                   .where(reason: "source_diff", source_key: FINAL_SOURCE_KEY)
                   .latest_first
                   .detect(&:reviewable_all_changes?)
      return unless version

      Result.new(version: version, status: :reused, reason: "existing_final_snapshot")
    end

    def from_live_branch
      return unless source_available?

      content = RepositoryContent.for(repository, user: user)
      history = content.history(base: content.resolve(job_base_branch), head: content.resolve(job.branch_name))
      head_sha = history.commits.first&.sha.to_s.presence
      base_sha = history.merge_base_id.to_s.presence
      return if base_sha.blank? || head_sha.blank? || base_sha == head_sha

      changes, truncated = diff_changes(content: content, base_sha: base_sha, head_sha: head_sha)
      files = changes.map { |change| file_hash(change) }
      return if files.empty?

      run = source_run_for(base_sha: base_sha, head_sha: head_sha)

      create_final_version(
        base_sha: base_sha,
        head_sha: head_sha,
        base_ref: job_base_branch,
        head_ref: job.branch_name,
        files: files,
        truncated: truncated,
        workflow: run&.workflow,
        run: run,
        source: truncated ? "live_branch_truncated" : "live_branch"
      )
    rescue RepositoryContent::Truncated => e
      materialize_truncated(e)
    rescue RepositoryContent::Error => e
      logger.info("[DiffReviewVersions::FinalSnapshot] skipped #{job.slug}: #{e.class}: #{e.message}")
      nil
    end

    def materialize_truncated(error)
      partial = Array(error.partial)
      if partial.first.respond_to?(:path)
        files = partial.map { |change| file_hash(change) }
        return if files.empty?
      else
        return
      end

      run = best_historical_run
      return unless run&.base_sha.present? && run&.head_sha.present? && run.base_sha != run.head_sha

      create_final_version(
        base_sha: run.base_sha,
        head_sha: run.head_sha,
        base_ref: job_base_branch,
        head_ref: job.branch_name,
        files: files,
        truncated: true,
        workflow: run.workflow,
        run: run,
        source: "live_branch_truncated"
      )
    end

    def diff_changes(content:, base_sha:, head_sha:)
      [ content.changes(base: content.resolve(base_sha), head: content.resolve(head_sha), patch: true), false ]
    rescue RepositoryContent::Truncated => e
      [ Array(e.partial), true ]
    end

    def from_historical_run
      run = best_historical_run
      return unless run

      diff = trusted_diff_for(run)
      files = DiffReviewVersions::UnifiedDiffFiles.parse(diff)
      return if files.empty?

      create_final_version(
        base_sha: run.base_sha,
        head_sha: run.head_sha,
        base_ref: job_base_branch,
        head_ref: job.branch_name,
        files: files,
        truncated: false,
        workflow: run.workflow,
        run: run,
        source: "run_diff"
      )
    end

    def create_final_version(base_sha:, head_sha:, base_ref:, head_ref:, files:, truncated:, workflow:, run:, source:)
      return if base_sha.blank? || head_sha.blank? || base_sha == head_sha || files.blank?

      job.with_lock do
        existing = job.diff_review_versions
                      .where(reason: "source_diff", source_key: FINAL_SOURCE_KEY)
                      .latest_first
                      .detect(&:reviewable_all_changes?)
        return Result.new(version: existing, status: :reused, reason: "existing_final_snapshot") if existing

        version = job.diff_review_versions.create!(
          version_index: DiffReviewVersion.next_index_for(job),
          workflow: workflow,
          run: run,
          base_sha: base_sha,
          head_sha: head_sha,
          base_ref: base_ref,
          head_ref: head_ref,
          source_key: FINAL_SOURCE_KEY,
          trigger_kind: workflow&.trigger_kind || run&.trigger_kind,
          label: "All changes",
          reason: "source_diff",
          truncated: truncated,
          files_snapshot: normalized_files(files),
          metadata: {
            "range_kind" => "all_changes",
            "final_snapshot" => true,
            "source" => source
          }
        )
        Result.new(version: version, status: :created, reason: source)
      end
    end

    def skipped(reason)
      Result.new(version: nil, status: :skipped, reason: reason)
    end

    def source_available?
      repository.installation&.active? || user&.github_token.present?
    end

    def job_base_branch
      job.mergeability_base_ref.presence || job.effective_base_branch.presence || repository.default_branch
    end

    def file_hash(change)
      status = change.status == "deleted" ? "removed" : change.status
      {
        path: change.path,
        status: status,
        additions: change.additions,
        deletions: change.deletions,
        patch: change.patch
      }
    end

    def normalized_files(files)
      Array(files).map do |file|
        {
          "path" => value_for(file, :path).to_s,
          "status" => value_for(file, :status).to_s,
          "additions" => value_for(file, :additions).to_i,
          "deletions" => value_for(file, :deletions).to_i,
          "patch" => value_for(file, :patch)
        }
      end
    end

    def value_for(file, key)
      return file[key] if file.is_a?(Hash) && file.key?(key)
      return file[key.to_s] if file.is_a?(Hash)

      file.public_send(key) if file.respond_to?(key)
    end

    def source_run_for(base_sha:, head_sha:)
      job.runs
         .includes(:step)
         .where(state: "succeeded", base_sha: base_sha, head_sha: head_sha)
         .reorder(created_at: :desc, id: :desc)
         .detect { |run| trusted_step?(run) }
    end

    def best_historical_run
      job.runs
         .includes(step: :workflow)
         .where(state: "succeeded")
         .where.not(base_sha: [ nil, "" ], head_sha: [ nil, "" ])
         .reorder(created_at: :desc, id: :desc)
         .detect do |run|
           run.base_sha != run.head_sha &&
             trusted_step?(run) &&
             trusted_diff_for(run).present?
         end
    end

    def trusted_step?(run)
      run.step.nil? || TRUSTED_STEP_KINDS.include?(run.step.kind)
    end

    def trusted_diff_for(run)
      run.step_agent_diff.presence || run.agent_diff.presence
    end
  end
end
