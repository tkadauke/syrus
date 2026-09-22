require "fileutils"
require "tmpdir"

module App
  # Resolves the project-scoped preview choices for a Job from the
  # repository's default-branch TargetGraph plus the Job branch diff,
  # read through RepositoryContent rather than the local bare clone
  # (`RepositoryBareClone`): this is read from web-tier request paths
  # (JobPreviewController, TargetGraphsController), and web pods don't mount
  # the worker's on-disk bare clone (see "Deploy target" in CLAUDE.md —
  # "Web pods don't need this volume"). Reading local disk here always saw
  # an absent clone and degraded to "no preview projects configured" for
  # every repository. Mirrors the fix RepositoryFeatureRecommendations
  # already applied for its own local-bare-clone reads. Content that cannot
  # be read (no provider, an outage) or an unpushed branch degrades to legacy
  # root behavior.
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

    # A backstop, not the invalidation mechanism -- the key already changes
    # the moment a `.syrus.yml` does. This only bounds how long an unused
    # entry for a repository nobody is looking at lingers.
    GRAPH_CACHE_TTL = 1.day

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

    CONFIG_GLOB = "**/#{SyrusYml::CONFIG_FILE}".freeze

    def initialize(job, repository: nil, user: nil)
      @job = job
      @repository = repository || job.repository
      @user = user || job&.user || @repository.user
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
      revision = content.resolve(repository.default_branch)
      entries = content.tree(revision, glob: CONFIG_GLOB).select(&:file?)
      return [] if entries.empty?

      cached_graph_choices(entries) { compile_graph_choices(entries, revision) }
    rescue StandardError => e
      Rails.logger.warn("[App::PreviewProjects] unavailable for #{repository.slug}: #{e.class}: #{e.message}")
      []
    end

    # The compiled graph depends on nothing but the default branch's
    # `.syrus.yml` files, so it is cached under their content ids: a new key
    # exactly when one of them changes, and the same key across every
    # unrelated commit to main.
    #
    # This is on the Job detail page's request path, which polls. Uncached,
    # every poll fetched each `.syrus.yml` in the repository one at a time --
    # 43 serial GitHub calls for Syrus's own repo. One open Job page drove
    # ~12k GitHub requests an hour, 94% of the App's entire traffic, pushed it
    # into rate limiting (which stalls polling for everything else), and spent
    # ~6s per request waiting on them. faraday-http-cache turned most of those
    # into 304s, which spared the quota but not the round trips.
    #
    # Only cached when every entry carries a content id. Without one there is
    # no exact key, and a guessed one would serve a stale graph after a config
    # change -- worse than the latency it saves.
    def cached_graph_choices(entries)
      return yield unless entries.all? { |entry| entry.content_id.present? }

      rows = Rails.cache.fetch(graph_cache_key(entries), expires_in: GRAPH_CACHE_TTL) do
        yield.map(&:to_h)
      end
      rows.map { |row| Choice.new(**row.transform_keys(&:to_sym)) }
    end

    def compile_graph_choices(entries, revision)
      Dir.mktmpdir("syrus-preview-projects") do |dir|
        materialize_syrus_yml_files!(dir, entries.map(&:path), revision)
        graph = TargetGraph::Compiler.compile(dir)
        graph.projects.values.select(&:preview).map { |project| choice_for(project) }
      end
    end

    def graph_cache_key(entries)
      digest = Digest::SHA256.hexdigest(entries.map { |entry| "#{entry.path}\0#{entry.content_id}" }.join("\n"))
      "syrus:preview_projects:v1:#{repository.id}:#{digest}"
    end

    # Only `.syrus.yml` files are fetched and written into the scratch
    # directory (not the whole tree) -- TargetGraph::Compiler and
    # TargetGraph::NestedConfigDiscovery only ever look for files named
    # `.syrus.yml` on disk, so this is enough to compile the full graph
    # without a full default-branch checkout. The tree is the committed
    # tree at the revision, so untracked/gitignored files are already
    # excluded -- no separate `git check-ignore` pass is needed the way the
    # local filesystem-walk version of NestedConfigDiscovery needs one.
    # Reading at the same Revision the tree came from keeps the cache key
    # (those files' content ids) describing exactly what was compiled.
    def materialize_syrus_yml_files!(dir, paths, revision)
      paths.each do |path|
        blob = content.read_if_present(revision, path)
        next unless blob

        full_path = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.binwrite(full_path, blob.bytes)
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

      base = content.resolve(job.effective_base_branch)
      head = content.resolve(job.branch_name)
      content.changes(base: base, head: head).map(&:path)
    rescue StandardError => e
      Rails.logger.warn("[App::PreviewProjects] could not resolve changed files for #{job.slug}: #{e.class}: #{e.message}")
      []
    end

    def content
      @content ||= RepositoryContent.for(repository, user: user)
    end
  end
end
