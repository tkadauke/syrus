require "fileutils"
require "tmpdir"

module App
  # Resolves the project-scoped preview choices for a Job from the repository's
  # default-branch TargetGraph plus the Job branch diff available in the local
  # bare clone. Missing clones or refs degrade to legacy root behavior.
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

    def initialize(job, repository: nil, git: GitRunner.new)
      @job = job
      @repository = repository || job.repository
      @git = git
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

    attr_reader :job, :repository, :git

    def project_choices
      graph_choices.presence || plugin_root_choice
    end

    def graph_choices
      return [] unless bare_clone_path.directory?

      with_default_branch_checkout do |path|
        graph = TargetGraph::Compiler.compile(path)
        graph.projects.values.select(&:preview).map { |project| choice_for(project) }
      end
    rescue StandardError => e
      Rails.logger.warn("[App::PreviewProjects] unavailable for #{repository.slug}: #{e.class}: #{e.message}")
      []
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

      choices.select { |choice| choice.path.blank? || project_path_matches?(choice.path, files) }
    end

    def project_path_matches?(path, files)
      files.any? { |file| file == path || file.start_with?("#{path}/") }
    end

    def changed_files
      return [] unless job&.branch_name.present?
      return [] unless bare_clone_path.directory?

      git.run(
        "--git-dir", bare_clone_path.to_s,
        "diff", "--name-only",
        "#{job.effective_base_branch}...#{job.branch_name}"
      ).split("\n").map(&:strip).reject(&:empty?)
    rescue GitRunner::GitError => e
      Rails.logger.warn("[App::PreviewProjects] could not resolve changed files for #{job.slug}: #{e.message}")
      []
    end

    def bare_clone_path
      @bare_clone_path ||= RepositoryBareClone.path_for(repository)
    end

    def with_default_branch_checkout
      Dir.mktmpdir("syrus-preview-projects") do |dir|
        git.run(
          "--git-dir", bare_clone_path.to_s,
          "--work-tree", dir,
          "checkout", "-f", repository.default_branch, "--", ".",
          chdir: dir
        )
        yield Pathname.new(dir)
      end
    end
  end
end
