module App
  class JobSourceDiffPayload
    def self.build(job:, user:, params: {})
      new(job: job, user: user, params: params).payload
    end

    def initialize(job:, user:, params:)
      @job = job
      @user = user
      @params = params
      @repository = job.repository
    end

    def payload
      return fixture_payload if preview_fixture.present?
      return unavailable_payload unless source_available?

      github = GithubClient.for(repository: @repository, user: @user)
      branch_commits = []
      merge_base_sha = nil

      if @job.branch_name.present?
        compare = github.compare_commits(@repository.slug, job_base_branch, @job.branch_name)
        branch_commits = Array(compare[:commits])
        merge_base_sha = compare[:merge_base_sha]
      end

      base = @params[:base].presence || merge_base_sha || job_base_branch
      head = @params[:head].presence || branch_commits.first&.fetch(:sha) || @repository.default_branch
      diff_result = github.compare_files(@repository.slug, base, head)
      version = persist_current_version(
        base_sha: base,
        head_sha: head,
        files: diff_result[:files],
        truncated: diff_result[:truncated] == true
      )

      base_payload(base_ref: base, head_ref: head, branch_commits: branch_commits, merge_base_sha: merge_base_sha)
        .merge(
          files: Array(diff_result[:files]).map { |file| file_json(file) },
          truncated: diff_result[:truncated] == true,
          diff_error: nil,
          version: version_json(version),
          versions: diff_versions_json
        )
    rescue => e
      base_payload(base_ref: nil, head_ref: nil)
        .merge(files: [], truncated: false, diff_error: e.message, version: nil, versions: diff_versions_json)
    end

    private

    # The Job's own PR/stack base, not the repository's default branch — an
    # Epic child Job stacked on a parent Job's branch must diff against that
    # parent branch, or the review shows every accumulated commit from the
    # start of the stack instead of just this Job's own changes.
    def job_base_branch
      @job.mergeability_base_ref.presence || @job.effective_base_branch.presence || @repository.default_branch
    end

    def source_available?
      @repository.installation&.active? || @user.github_token.present?
    end

    # Preview-only escape hatch: `Job#diff_fixture` is populated exclusively by
    # db/seeds.rb for the seeded demo Job, so the diff-review UI has real
    # file/patch content to render in a preview environment that has no
    # GitHub credentials at all. The `Rails.env.development?` guard is
    # defense in depth on top of the column only ever being written there.
    def preview_fixture
      return nil unless Rails.env.development?

      @job.diff_fixture
    end

    def fixture_payload
      fixture = preview_fixture.deep_symbolize_keys
      base_payload(
        base_ref: fixture[:base_ref],
        head_ref: fixture[:head_ref],
        branch_commits: fixture.fetch(:branch_commits, []),
        merge_base_sha: fixture[:merge_base_sha]
      ).merge(
        files: Array(fixture[:files]).map { |file| file_json(file) },
        truncated: false,
        diff_error: nil,
        version: nil,
        versions: diff_versions_json
      )
    end

    def unavailable_payload
      base_payload(base_ref: nil, head_ref: nil)
        .merge(
          files: [],
          truncated: false,
          diff_error: "GitHub token not configured. Add one in Settings to browse source.",
          version: nil,
          versions: diff_versions_json
        )
    end

    def base_payload(base_ref:, head_ref:, branch_commits: [], merge_base_sha: nil)
      {
        job_id: @job.id,
        base_ref: base_ref,
        head_ref: head_ref,
        merge_base_sha: merge_base_sha,
        default_ref: @repository.default_branch,
        branch_commits: branch_commits.map { |commit| commit_json(commit) }
      }
    end

    def commit_json(commit)
      {
        sha: commit[:sha],
        short_sha: commit[:short_sha].presence || commit[:sha].to_s.first(7),
        message: commit[:message].to_s,
        date: iso8601(commit[:date])
      }
    end

    def file_json(file)
      {
        path: file[:path].to_s,
        status: file[:status].to_s,
        additions: file[:additions].to_i,
        deletions: file[:deletions].to_i,
        patch: file[:patch]
      }
    end

    def iso8601(value)
      value.respond_to?(:iso8601) ? value.iso8601 : value&.to_s
    end

    def persist_current_version(base_sha:, head_sha:, files:, truncated:)
      return nil if @params[:base].present? || @params[:head].present?

      source_run = source_run_for(base_sha: base_sha, head_sha: head_sha)
      source_workflow = source_run&.workflow || @job.latest_workflow
      trigger_kind = source_workflow&.trigger_kind || source_run&.trigger_kind
      DiffReviewVersions::Creator.call(
        job: @job,
        base_sha: base_sha,
        head_sha: head_sha,
        files: files,
        truncated: truncated,
        base_ref: job_base_branch,
        head_ref: @job.branch_name,
        workflow: source_workflow,
        run: source_run,
        trigger_kind: trigger_kind,
        reason: trigger_kind.to_s.presence || "source_diff"
      )
    rescue => e
      Rails.logger.warn("[JobSourceDiffPayload] could not persist diff review version for #{@job.slug}: #{e.class}: #{e.message}")
      nil
    end

    def source_run_for(base_sha:, head_sha:)
      @job.runs
          .includes(:step)
          .where(base_sha: base_sha, head_sha: head_sha)
          .reorder(created_at: :desc, id: :desc)
          .first ||
        @job.runs
            .includes(:step)
            .where(head_sha: head_sha)
            .reorder(created_at: :desc, id: :desc)
            .first
    end

    def version_json(version)
      return nil unless version

      {
        id: version.id,
        version_index: version.version_index,
        base_sha: version.base_sha,
        head_sha: version.head_sha,
        label: version.label,
        reason: version.reason
      }
    end

    def diff_versions_json
      @job.diff_review_versions.ordered.map do |version|
        {
          id: version.id,
          version_index: version.version_index,
          base_sha: version.base_sha,
          head_sha: version.head_sha,
          label: version.label,
          reason: version.reason,
          created_at: version.created_at&.iso8601
        }
      end
    end
  end
end
