require "fileutils"
require "json"

class PreviewWorkspace
  def self.data_root
    Pathname.new(ENV["SYRUS_DATA_ROOT"] || File.expand_path("~/.syrus"))
  end

  def self.path_for(preview_environment)
    data_root.join("previews", preview_environment.id.to_s)
  end

  # revision: :head (default) checks out the Job's feature branch — today's
  # behavior, unchanged for every existing caller. revision: :base checks out
  # the Job's base revision instead, resolved fresh via `git merge-base
  # <effective_base_branch> <head>` so stacked Jobs compare against their real
  # parent branch rather than always the repo default branch. Not persisted —
  # recomputed on every prepare! call.
  def self.prepare!(preview_environment, git: GitRunner.new, revision: :head)
    new(preview_environment, git: git, revision: revision).prepare!
  end

  def self.cleanup_for(preview_environment)
    path = preview_environment.workspace_path.presence || path_for(preview_environment).to_s
    FileUtils.rm_rf(path)
    preview_environment.update_columns(workspace_path: nil, updated_at: Time.current)
  rescue StandardError => e
    Rails.logger.warn("[PreviewWorkspace] cleanup failed for PreviewEnvironment ##{preview_environment.id}: #{e.class}: #{e.message}")
  end

  def initialize(preview_environment, git:, revision: :head)
    @preview_environment = preview_environment
    @job = preview_environment.job
    @repository = @job.repository
    @git = git
    @revision = revision
    @path = self.class.path_for(preview_environment)
    @env = { "GIT_TERMINAL_PROMPT" => "0" }
  end

  def prepare!
    raise "job has no branch to preview" if @job.branch_name.blank?

    FileUtils.rm_rf(@path)
    FileUtils.mkdir_p(@path.dirname)
    @git.run(
      "clone",
      "--branch", @job.branch_name,
      "--no-tags", authenticated_url, @path.to_s,
      env: @env
    )
    @git.run("remote", "set-url", "origin", @repository.remote_url, chdir: @path.to_s)
    checkout_base_revision! if base_revision?
    @git.configure_author(BotIdentity.for(@job), chdir: @path.to_s)
    apply_preview_asset_proxy_overrides!
    @preview_environment.update_columns(workspace_path: @path.to_s, updated_at: Time.current)
    @path.to_s
  rescue StandardError
    FileUtils.rm_rf(@path)
    raise
  end

  private

  def base_revision?
    @revision == :base
  end

  # Non-shallow clone (no --depth above) fetches every branch as a
  # remote-tracking ref regardless of --branch, so origin/<effective base
  # branch> is already present locally — no extra fetch needed.
  def checkout_base_revision!
    base_ref = "origin/#{@job.effective_base_branch}"
    base_sha = @git.run("merge-base", base_ref, "HEAD", chdir: @path.to_s).strip
    @git.run("checkout", base_sha, chdir: @path.to_s)
  end

  def authenticated_url
    @repository.authenticated_url(user: @job.user)
  end

  # Preview workspaces are disposable copies. It is safe to patch framework
  # development-server config here when the original repo would otherwise emit
  # browser-facing localhost asset URLs that cannot work through Syrus's preview
  # domain.
  def apply_preview_asset_proxy_overrides!
    vite_config = @path.join("config", "vite.json")
    return unless vite_config.file?

    config = JSON.parse(vite_config.read)
    changed = false
    %w[all development].each do |section|
      next unless config[section].is_a?(Hash)
      next unless config[section].key?("skipProxy")

      config[section]["skipProxy"] = false
      changed = true
    end
    return unless changed

    vite_config.write("#{JSON.pretty_generate(config)}\n")
  rescue JSON::ParserError => e
    Rails.logger.warn("[PreviewWorkspace] could not patch Vite preview config for #{@job.slug}: #{e.message}")
  end
end
