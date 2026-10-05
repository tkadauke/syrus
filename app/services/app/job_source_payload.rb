module App
  class JobSourcePayload
    include Rails.application.routes.url_helpers

    LANGUAGE_BY_EXTENSION = {
      "rb" => "ruby",
      "rake" => "ruby",
      "gemspec" => "ruby",
      "js" => "javascript",
      "mjs" => "javascript",
      "cjs" => "javascript",
      "ts" => "typescript",
      "jsx" => "javascript",
      "tsx" => "typescript",
      "py" => "python",
      "erb" => "erb",
      "html" => "html",
      "htm" => "html",
      "css" => "css",
      "scss" => "scss",
      "sass" => "sass",
      "json" => "json",
      "yml" => "yaml",
      "yaml" => "yaml",
      "md" => "markdown",
      "sh" => "shell",
      "bash" => "shell",
      "zsh" => "shell",
      "go" => "go",
      "java" => "java",
      "rs" => "rust",
      "php" => "php",
      "sql" => "sql",
      "xml" => "xml",
      "svg" => "xml",
      "toml" => "toml",
      "tf" => "hcl"
    }.freeze

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

      history = branch_history
      branch_commits = history.commits.map { |commit| commit_hash(commit) }
      merge_base_sha = history.merge_base_id

      selected_ref = @params[:ref].presence || branch_commits.first&.fetch(:sha) || merge_base_sha || @repository.default_branch
      tree_result = load_tree(selected_ref)
      selected_path = @params[:path].presence

      base_payload(selected_ref: selected_ref, selected_path: selected_path, branch_commits: branch_commits, merge_base_sha: merge_base_sha)
        .merge(tree_result)
        .merge(file_result(selected_path, tree_result[:source_error]))
    rescue => e
      base_payload(selected_ref: @params[:ref].presence || @repository.default_branch, selected_path: @params[:path].presence)
        .merge(tree_items: [], tree_truncated: false, file: nil, source_error: e.message, file_error: nil)
    end

    private

    def source_available?
      @repository.installation&.active? || @user.github_token.present?
    end

    def unavailable_payload
      base_payload(selected_ref: @params[:ref].presence || @repository.default_branch, selected_path: @params[:path].presence)
        .merge(
          tree_items: [],
          tree_truncated: false,
          file: nil,
          source_error: "GitHub token not configured. Add one in Settings to browse source.",
          file_error: nil
        )
    end

    # Files larger than this are shown truncated; the payload says so.
    MAX_FILE_BYTES = 1.megabyte

    def preview_fixture
      return nil unless Rails.env.development?

      @job.diff_fixture
    end

    def fixture_payload
      fixture = preview_fixture.deep_symbolize_keys
      selected_ref = @params[:ref].presence || fixture[:head_sha].presence || fixture[:head_ref].presence || @repository.default_branch
      selected_path = @params[:path].presence
      files = fixture_source_files(fixture, selected_ref)

      base_payload(
        selected_ref: selected_ref,
        selected_path: selected_path,
        branch_commits: Array(fixture[:branch_commits]),
        merge_base_sha: fixture[:merge_base_sha]
      )
        .merge(
          tree_items: files.map { |path, content| fixture_tree_item_json(path, content) },
          tree_truncated: false,
          source_error: nil
        )
        .merge(fixture_file_result(selected_path, files))
    end

    def fixture_source_files(fixture, selected_ref)
      source_files = fixture[:source_files]
      return {} unless source_files.is_a?(Hash)

      head_ref = fixture[:head_sha].presence || fixture[:head_ref]
      base_ref = fixture[:base_sha].presence || fixture[:merge_base_sha].presence || fixture[:base_ref]
      selected_key =
        if selected_ref == head_ref
          :head
        elsif selected_ref == base_ref
          :base
        else
          selected_ref.to_s
        end

      files = source_files[selected_key] || source_files[selected_key.to_s] || {}
      files.to_h.transform_keys(&:to_s).sort.to_h
    end

    def fixture_file_result(selected_path, files)
      return { file: nil, file_error: nil } if selected_path.blank?

      content = files[selected_path]
      return { file: nil, file_error: "File not found." } unless content

      {
        file: {
          path: selected_path,
          name: File.basename(selected_path),
          size: content.to_s.bytesize,
          language: language_for(selected_path),
          content: content.to_s,
          truncated: false
        },
        file_error: nil
      }
    end

    def fixture_tree_item_json(path, content)
      {
        path: path,
        name: File.basename(path),
        size: content.to_s.bytesize,
        language: language_for(path)
      }
    end

    def content
      @content ||= RepositoryContent.for(@repository, user: @user)
    end

    # Commits the branch introduced since its merge base with the default
    # branch, through RepositoryContent -- the git mirror when it can,
    # GitHub otherwise. A truncated answer (GitHub's 250-commit cap) is
    # still shown, same as a complete one always was.
    def branch_history
      return RepositoryContent::CommitHistory.new(commits: [], merge_base_id: nil) unless @job.branch_name.present?

      content.history(base: content.resolve(@repository.default_branch), head: content.resolve(@job.branch_name))
    rescue RepositoryContent::Truncated => e
      e.partial
    end

    def commit_hash(commit)
      { sha: commit.sha, message: commit.message, date: commit.authored_at }
    end

    def load_tree(selected_ref)
      @selected_revision = content.resolve(selected_ref)
      entries, truncated = tree_entries(@selected_revision)
      {
        tree_items: entries.select(&:file?).sort_by(&:path).map { |entry| tree_item_json(entry) },
        tree_truncated: truncated,
        source_error: nil
      }
    rescue => e
      {
        tree_items: [],
        tree_truncated: false,
        source_error: "Could not load file tree: #{e.message}"
      }
    end

    # A tree too large for GitHub to list in full (and no mirror to ask) is
    # still browsable: show what came back, flagged.
    def tree_entries(revision)
      [ content.tree(revision), false ]
    rescue RepositoryContent::Truncated => e
      [ e.partial, true ]
    end

    def file_result(selected_path, source_error)
      return { file: nil, file_error: nil } if selected_path.blank? || source_error.present?

      blob = content.read_if_present(@selected_revision, selected_path, max_bytes: MAX_FILE_BYTES)
      return { file: nil, file_error: "File not found." } unless blob

      {
        file: {
          path: selected_path,
          name: File.basename(selected_path),
          size: blob.size.to_i,
          language: language_for(selected_path),
          content: blob.text,
          truncated: blob.truncated
        },
        file_error: nil
      }
    rescue => e
      { file: nil, file_error: e.message }
    end

    def base_payload(selected_ref:, selected_path:, branch_commits: [], merge_base_sha: nil)
      {
        job_id: @job.id,
        repository: {
          id: @repository.id,
          slug: @repository.slug,
          default_branch: @repository.default_branch,
          repository_path: repository_path(@repository)
        },
        branch_name: @job.branch_name,
        default_ref: @repository.default_branch,
        selected_ref: selected_ref,
        selected_path: selected_path,
        merge_base_sha: merge_base_sha,
        branch_commits: branch_commits.map { |commit| commit_json(commit) },
        paths: {
          job_path: job_path(@job),
          source_path: source_job_path(@job),
          app_source_path: "/api/v1/app/jobs/#{@job.id}/source"
        }
      }
    end

    def tree_item_json(entry)
      path = entry.path
      {
        path: path,
        name: File.basename(path),
        size: entry.size.to_i,
        language: language_for(path)
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

    def language_for(path)
      LANGUAGE_BY_EXTENSION.fetch(File.extname(path.to_s).downcase.delete_prefix("."), "plaintext")
    end

    def iso8601(value)
      value.respond_to?(:iso8601) ? value.iso8601 : value&.to_s
    end
  end
end
