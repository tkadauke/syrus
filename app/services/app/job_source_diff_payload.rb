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
        compare = github.compare_commits(@repository.slug, @repository.default_branch, @job.branch_name)
        branch_commits = Array(compare[:commits])
        merge_base_sha = compare[:merge_base_sha]
      end

      base = @params[:base].presence || merge_base_sha || @repository.default_branch
      head = @params[:head].presence || branch_commits.first&.fetch(:sha) || @repository.default_branch
      diff_result = github.compare_files(@repository.slug, base, head)

      base_payload(base_ref: base, head_ref: head, branch_commits: branch_commits, merge_base_sha: merge_base_sha)
        .merge(files: Array(diff_result[:files]).map { |file| file_json(file) }, truncated: diff_result[:truncated] == true, diff_error: nil)
    rescue => e
      base_payload(base_ref: nil, head_ref: nil)
        .merge(files: [], truncated: false, diff_error: e.message)
    end

    private

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
        diff_error: nil
      )
    end

    def unavailable_payload
      base_payload(base_ref: nil, head_ref: nil)
        .merge(files: [], truncated: false, diff_error: "GitHub token not configured. Add one in Settings to browse source.")
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
  end
end
