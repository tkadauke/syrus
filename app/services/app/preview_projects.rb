require "fileutils"
require "tmpdir"

module App
  # Resolves the project-scoped preview choices for a Job from the
  # repository's default-branch TargetGraph plus the Job branch diff,
  # fetched through GitHub (GithubClient) rather than the local bare clone
  # (`RepositoryBareClone`): this is read from web-tier request paths
  # (JobPreviewController, TargetGraphsController), and web pods don't mount
  # the worker's on-disk bare clone (see "Deploy target" in CLAUDE.md —
  # "Web pods don't need this volume"). Reading local disk here always saw
  # an absent clone and degraded to "no preview projects configured" for
  # every repository. Mirrors the fix RepositoryFeatureRecommendations
  # already applied for its own local-bare-clone reads. Missing credentials
  # or an unpushed branch degrade to legacy root behavior, same as before.
  class PreviewProjects
    Choice = Data.define(:id, :label, :path, :owner_config_path) do
      def to_h
        {
          "id" => id,
          "label" => label,
          "path" => path,
          "owner_config_path" => owner_config_path
        }
      end
    end

    Result = Data.define(:choices, :unavailable_reason) do
      def available? = choices.any?
      def single? = choices.one?
      def choice(id) = choices.find { |candidate| candidate.id == id.to_s }
      def to_a = choices.map(&:to_h)
    end

    def self.for_job(job)
      new(job).for_job
    end

    def self.for_repository(repository)
      new(nil, repository: repository).for_repository
    end

    def initialize(job, repository: nil, user: nil, client: nil)
      @job = job
      @repository = repository || job.repository
      @user = user || job&.user || @repository.user
      @client = client
    end

    def for_job
      choices = project_choices
      return Result.new(choices: [], unavailable_reason: "no_preview_configured") if choices.empty?

      affected = affected_choices(choices)
      return Result.new(choices: [], unavailable_reason: "no_affected_preview_project") if affected.empty?

      Result.new(choices: affected, unavailable_reason: nil)
    end

    def for_repository
      choices = project_choices
      Result.new(choices: choices, unavailable_reason: choices.empty? ? "no_preview_configured" : nil)
    end

    private

    attr_reader :job, :repository, :user

    def project_choices
      graph_choices.presence || plugin_root_choice
    end

    def graph_choices
      return [] unless github_client

      paths = config_paths
      return [] if paths.empty?

      Dir.mktmpdir("syrus-preview-projects") do |dir|
        materialize_syrus_yml_files!(dir, paths)
        graph = TargetGraph::Compiler.compile(dir)
        graph.projects.values.select(&:preview).map { |project| choice_for(project) }
      end
    rescue StandardError => e
      Rails.logger.warn("[App::PreviewProjects] unavailable for #{repository.slug}: #{e.class}: #{e.message}")
      []
    end

    # Only `.syrus.yml` files are fetched and written into the scratch
    # directory (not the whole tree) -- TargetGraph::Compiler and
    # TargetGraph::NestedConfigDiscovery only ever look for files named
    # `.syrus.yml` on disk, so this is enough to compile the full graph
    # without a full default-branch checkout. `file_tree_at` walks the git
    # tree at the ref, so untracked/gitignored files are already excluded --
    # no separate `git check-ignore` pass is needed the way the local
    # filesystem-walk version of NestedConfigDiscovery needs one.
    def materialize_syrus_yml_files!(dir, paths)
      paths.each do |path|
        file = github_client.file_content_at(repository.slug, path, repository.default_branch)
        next unless file

        full_path = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.write(full_path, file.fetch(:content))
      end
    end

    def config_paths
      tree = github_client.file_tree_at(repository.slug, repository.default_branch)
      Array(tree[:items]).map { |item| item[:path] }.select do |path|
        path == SyrusYml::CONFIG_FILE || path.end_with?("/#{SyrusYml::CONFIG_FILE}")
      end
    end

    def plugin_root_choice
      return [] unless Syrus::Plugin::PreviewProvider.configured?

      [ Choice.new(id: TargetGraph::ROOT_PROJECT_ID, label: "Repository", path: "", owner_config_path: nil) ]
    end

    def choice_for(project)
      Choice.new(
        id: project.id,
        label: project.label,
        path: project.path,
        owner_config_path: project.owner_config_path
      )
    end

    def affected_choices(choices)
      files = changed_files
      return choices if files.empty?

      nested_choices = choices.reject { |choice| choice.path.blank? }
      affected_nested = nested_choices.select { |choice| project_path_matches?(choice.path, files) }
      root_choices = choices.select { |choice| choice.path.blank? }
      root_owned_files = files.reject { |file| nested_choices.any? { |choice| project_path_matches?(choice.path, [ file ]) } }

      affected_nested + (root_owned_files.any? ? root_choices : [])
    end

    def project_path_matches?(path, files)
      files.any? { |file| file == path || file.start_with?("#{path}/") }
    end

    def changed_files
      return [] unless job&.branch_name.present?
      return [] unless github_client

      result = github_client.compare_files(repository.slug, job.effective_base_branch, job.branch_name)
      Array(result[:files]).map { |file| file[:path] }
    rescue StandardError => e
      Rails.logger.warn("[App::PreviewProjects] could not resolve changed files for #{job.slug}: #{e.class}: #{e.message}")
      []
    end

    def github_client
      return @client if @client
      return @github_client if defined?(@github_client)
      return @github_client = nil unless repository.installation&.active? || user&.github_token.present?

      @github_client = GithubClient.for(repository: repository, user: user)
    rescue StandardError => e
      Rails.logger.warn("[App::PreviewProjects] GitHub client unavailable for #{repository.slug}: #{e.class}: #{e.message}")
      @github_client = nil
    end
  end
end
