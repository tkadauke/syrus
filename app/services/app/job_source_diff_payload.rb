module App
  class JobSourceDiffPayload
    IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .gif .webp .svg .bmp .ico].freeze

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

      # Defaulted up front, not just inside branch_history, so the rescue
      # below still has something to hand stored_review_version_payload if
      # RepositoryContent itself raises before branch_history returns.
      branch_commits = []
      merge_base_sha = nil
      history = branch_history
      branch_commits = history.commits.map { |commit| commit_hash(commit) }
      merge_base_sha = history.merge_base_id

      if @job.branch_name.present? && branch_commits.empty? && !explicit_selection?
        return stored_review_version_payload(branch_commits: branch_commits, merge_base_sha: merge_base_sha)
      end

      base = @params[:base].presence || merge_base_sha || job_base_branch
      head = @params[:head].presence || branch_commits.first&.fetch(:sha) || merge_base_sha || @repository.default_branch
      files, truncated = diff_files(base, head)
      version = resolve_diff_review_version(
        base_sha: base,
        head_sha: head,
        files: files,
        truncated: truncated
      )

      base_payload(base_ref: base, head_ref: head, base_sha: base, head_sha: head, branch_commits: branch_commits, merge_base_sha: merge_base_sha)
        .merge(
          files: files.map { |file| file_json(file) },
          truncated: truncated,
          diff_error: nil,
          version: version_json(version),
          versions: diff_versions_json
        )
    rescue => e
      if @job.branch_name.present? && !explicit_selection?
        version = DiffReviewVersion.default_for_review(@job)
        return stored_review_version_payload(branch_commits: branch_commits, merge_base_sha: merge_base_sha) if version
      end

      base_payload(base_ref: nil, head_ref: nil)
        .merge(files: [], truncated: false, diff_error: e.message, version: nil, versions: diff_versions_json)
    end

    private

    # The diff UI and stored review versions use GitHub's status names; the
    # content contract says "deleted" where GitHub says "removed".
    UI_STATUS = { "deleted" => "removed" }.freeze

    # Files changed from base to head, through RepositoryContent -- the git
    # mirror when it can, GitHub otherwise. A truncated answer (GitHub's
    # 300-file cap) is still shown, flagged, as it always was.
    def diff_files(base, head)
      content = RepositoryContent.for(@repository, user: @user)
      changes = content.changes(base: content.resolve(base), head: content.resolve(head), patch: true)
      [ changes.map { |change| file_hash(change) }, false ]
    rescue RepositoryContent::Truncated => e
      [ e.partial.map { |change| file_hash(change) }, true ]
    end

    # Commits the branch introduced since its merge base with the Job's own
    # base branch, through RepositoryContent -- the git mirror when it can,
    # GitHub otherwise. A truncated answer (GitHub's 250-commit cap) is
    # still shown, same as a complete one always was.
    def branch_history
      return RepositoryContent::CommitHistory.new(commits: [], merge_base_id: nil) unless @job.branch_name.present?

      content = RepositoryContent.for(@repository, user: @user)
      content.history(base: content.resolve(job_base_branch), head: content.resolve(@job.branch_name))
    rescue RepositoryContent::Truncated => e
      e.partial
    end

    def commit_hash(commit)
      { sha: commit.sha, message: commit.message, date: commit.authored_at }
    end

    def file_hash(change)
      {
        path: change.path,
        status: UI_STATUS.fetch(change.status, change.status),
        additions: change.additions,
        deletions: change.deletions,
        patch: change.patch
      }
    end

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

    def explicit_selection?
      @params[:base].present? || @params[:head].present?
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
      version = fixture_diff_review_version(fixture)
      base_payload(
        base_ref: fixture[:base_ref],
        head_ref: fixture[:head_ref],
        base_sha: fixture[:base_sha].presence || fixture[:merge_base_sha].presence || fixture[:base_ref],
        head_sha: fixture[:head_sha].presence || fixture[:head_ref],
        branch_commits: fixture.fetch(:branch_commits, []),
        merge_base_sha: fixture[:merge_base_sha]
      ).merge(
        files: Array(fixture[:files]).map { |file| file_json(file) },
        truncated: false,
        diff_error: nil,
        version: version_json(version),
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

    def stored_review_version_payload(branch_commits:, merge_base_sha:)
      version = DiffReviewVersion.default_for_review(@job)
      return no_branch_diff_payload(branch_commits: branch_commits, merge_base_sha: merge_base_sha) unless version

      base_payload(
        base_ref: version.base_ref.presence || version.base_sha,
        head_ref: version.head_ref.presence || version.head_sha,
        base_sha: version.base_sha,
        head_sha: version.head_sha,
        branch_commits: branch_commits,
        merge_base_sha: merge_base_sha
      ).merge(
        files: Array(version.files_snapshot).map { |file| stored_file_json(file) },
        truncated: version.truncated,
        diff_error: nil,
        version: version_json(version),
        versions: diff_versions_json
      )
    end

    def no_branch_diff_payload(branch_commits:, merge_base_sha:)
      ref = merge_base_sha.presence || job_base_branch
      base_payload(base_ref: ref, head_ref: ref, base_sha: ref, head_sha: ref, branch_commits: branch_commits, merge_base_sha: merge_base_sha)
        .merge(
          files: [],
          truncated: false,
          diff_error: nil,
          version: nil,
          versions: diff_versions_json
        )
    end

    def base_payload(base_ref:, head_ref:, base_sha: nil, head_sha: nil, branch_commits: [], merge_base_sha: nil)
      {
        job_id: @job.id,
        base_ref: base_ref,
        head_ref: head_ref,
        base_sha: base_sha,
        head_sha: head_sha,
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
        patch: file[:patch],
        is_image: image_file?(file[:path]) && file[:patch].nil?
      }
    end

    def stored_file_json(file)
      {
        path: file["path"].to_s,
        status: file["status"].to_s,
        additions: file["additions"].to_i,
        deletions: file["deletions"].to_i,
        patch: file["patch"],
        is_image: image_file?(file["path"]) && file["patch"].nil?
      }
    end

    # Binary/large-file detection isn't a real flag from GitHub's compare API
    # -- it's inferred from `patch` being nil. For files that are also nil
    # because of that AND look like an image by extension, the frontend can
    # render before/after thumbnails instead of the generic placeholder.
    def image_file?(path)
      IMAGE_EXTENSIONS.include?(File.extname(path.to_s).downcase)
    end

    def iso8601(value)
      value.respond_to?(:iso8601) ? value.iso8601 : value&.to_s
    end

    # Deliberately never mutates a previously persisted DiffReviewVersion:
    # only an exact base_sha/head_sha match is reused as-is, and any other
    # base/head pair -- including a new "current" computation for the same
    # Job -- gets its own immutable row via DiffReviewVersions::Creator.
    # Overwriting whatever "All changes" row happened to exist most recently
    # (the previous behavior) let a single live-recomputed request corrupt
    # unrelated stored history and made repeated reads of "the same"
    # selection flicker between different base/head/file-count realities.
    def resolve_diff_review_version(base_sha:, head_sha:, files:, truncated:)
      existing_version = existing_version_for(base_sha: base_sha, head_sha: head_sha)
      return existing_version if existing_version

      source_run = source_run_for(base_sha: base_sha, head_sha: head_sha)
      explicit_selection = explicit_selection?
      source_workflow = source_run&.workflow || (explicit_selection ? nil : @job.latest_workflow)
      trigger_kind = source_workflow&.trigger_kind || source_run&.trigger_kind
      range_kind = explicit_selection ? "explicit_selection" : "all_changes"

      DiffReviewVersions::Creator.call(
        job: @job,
        base_sha: base_sha,
        head_sha: head_sha,
        files: files,
        truncated: truncated,
        base_ref: explicit_selection ? base_sha : job_base_branch,
        head_ref: explicit_selection ? head_sha : @job.branch_name,
        workflow: source_workflow,
        run: source_run,
        trigger_kind: trigger_kind,
        label: explicit_selection ? nil : "All changes",
        reason: explicit_selection ? "source_diff_selection" : "source_diff",
        metadata: { "range_kind" => range_kind }
      )
    rescue => e
      Rails.logger.warn("[JobSourceDiffPayload] could not persist diff review version for #{@job.slug}: #{e.class}: #{e.message}")
      nil
    end

    def existing_version_for(base_sha:, head_sha:)
      version_id = @job.diff_review_versions
                       .where(base_sha: base_sha, head_sha: head_sha)
                       .latest_first
                       .pick(:id)
      version_id ? @job.diff_review_versions.find_by(id: version_id) : nil
    end

    def fixture_diff_review_version(fixture)
      base_sha = fixture[:base_sha].presence || fixture[:merge_base_sha].presence || fixture[:base_ref]
      head_sha = fixture[:head_sha].presence || fixture[:head_ref]
      existing_version_for(base_sha: base_sha, head_sha: head_sha) ||
        DiffReviewVersions::Creator.call(
          job: @job,
          base_sha: base_sha,
          head_sha: head_sha,
          files: fixture[:files],
          truncated: false,
          base_ref: fixture[:base_ref],
          head_ref: fixture[:head_ref],
          label: "Preview fixture",
          reason: "diff_fixture"
        )
    rescue => e
      Rails.logger.warn("[JobSourceDiffPayload] could not persist fixture diff review version for #{@job.slug}: #{e.class}: #{e.message}")
      nil
    end

    def source_run_for(base_sha:, head_sha:)
      run_id = source_run_id_for(base_sha: base_sha, head_sha: head_sha)
      run_id ? Run.includes(step: :workflow).find_by(id: run_id) : nil
    end

    # Keep this lookup narrow. `runs` has large text/blob columns such as
    # prompt, agent_diff, and step_agent_diff; sorting full Run rows can exhaust
    # MySQL's sort buffer on busy Jobs even when the result is one row.
    def source_run_id_for(base_sha:, head_sha:)
      source_run_scope(base_sha: base_sha, head_sha: head_sha).pick(:id) ||
        source_run_scope(head_sha: head_sha).pick(:id)
    end

    def source_run_scope(base_sha: nil, head_sha:)
      scope = Run.where(job_id: @job.id).select(:id).where(head_sha: head_sha)
      scope = scope.where(base_sha: base_sha) if base_sha.present?
      scope.reorder(created_at: :desc, id: :desc)
    end

    def version_json(version)
      return nil unless version

      {
        id: version.id,
        job_id: version.job_id,
        version_index: version.version_index,
        base_sha: version.base_sha,
        head_sha: version.head_sha,
        base_ref: version.base_ref,
        head_ref: version.head_ref,
        workflow_id: version.workflow_id,
        workflow: version.workflow ? {
          id: version.workflow.id,
          trigger_kind: version.workflow.trigger_kind,
          state: version.workflow.state
        } : nil,
        run_id: version.run_id,
        trigger_kind: version.trigger_kind,
        label: version.label,
        reason: version.reason,
        truncated: version.truncated,
        files_count: Array(version.files_snapshot).size,
        comments_count: comments_count_for(version),
        metadata: version.metadata || {},
        created_at: version.created_at&.iso8601
      }
    end

    def diff_versions_json
      diff_review_versions_for_index.map do |version|
        {
          id: version.id,
          version_index: version.version_index,
          base_sha: version.base_sha,
          head_sha: version.head_sha,
          base_ref: version.base_ref,
          head_ref: version.head_ref,
          workflow_id: version.workflow_id,
          workflow: version.workflow ? {
            id: version.workflow.id,
            trigger_kind: version.workflow.trigger_kind,
            state: version.workflow.state
          } : nil,
          run_id: version.run_id,
          trigger_kind: version.trigger_kind,
          label: version.label,
          reason: version.reason,
          truncated: version.truncated,
          files_count: version.files_snapshot_count.to_i,
          comments_count: comments_count_for(version),
          metadata: version.metadata || {},
          created_at: version.created_at&.iso8601
        }
      end
    end

    def diff_review_versions_for_index
      @job.diff_review_versions
          .select(
            :id, :job_id, :workflow_id, :run_id, :version_index,
            :base_sha, :head_sha, :base_ref, :head_ref, :trigger_kind,
            :label, :reason, :truncated, :metadata, :created_at,
            Arel.sql("#{files_snapshot_count_sql} AS files_snapshot_count")
          )
          .includes(:workflow, :run)
          .ordered
    end

    def files_snapshot_count_sql
      adapter = DiffReviewVersion.connection.adapter_name.to_s.downcase
      adapter.include?("mysql") ? "JSON_LENGTH(files_snapshot)" : "json_array_length(files_snapshot)"
    end

    def comments_count_for(version)
      comments_count_by_version[version.id].to_i
    end

    def comments_count_by_version
      @comments_count_by_version ||= @job.diff_review_comments.group(:diff_review_version_id).count
    end
  end
end
