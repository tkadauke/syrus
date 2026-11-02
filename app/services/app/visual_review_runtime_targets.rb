module App
  # Compiles repository visual-review configuration into provider-neutral
  # RuntimeSession targets. Repositories using the original preview contract
  # receive equivalent browser targets, so existing browser reviews do not
  # need a configuration migration.
  class VisualReviewRuntimeTargets
    Target = Data.define(
      :name, :provider, :workspace_path, :launch, :build, :dimensions,
      :review_notes, :when_files_changed, :captures, :legacy_browser
    ) do
      def to_h
        {
          "name" => name,
          "provider" => provider,
          "workspace_path" => workspace_path,
          "launch" => launch,
          "build" => build,
          "dimensions" => dimensions,
          "review_notes" => review_notes,
          "when_files_changed" => when_files_changed,
          "captures" => captures,
          "legacy_browser" => legacy_browser
        }.compact
      end
    end

    def self.call(workspace_path:, changed_files:, preview_projects:)
      new(workspace_path, changed_files: changed_files, preview_projects: preview_projects).call
    end

    def initialize(workspace_path, changed_files:, preview_projects:)
      @workspace_path = Pathname.new(workspace_path)
      @changed_files = Array(changed_files)
      @preview_projects = preview_projects
    end

    def call
      configured = Array(config&.targets)
      return configured.filter_map { |target| configured_target(target) } if configured.any?

      return [] unless preview_projects.available?

      preview_projects.to_a.map do |project|
        path = project["path"].presence
        Target.new(
          name: project["label"].presence || "Browser",
          provider: "browser",
          workspace_path: path ? workspace_path.join(path).to_s : workspace_path.to_s,
          launch: {}, build: {}, dimensions: nil,
          review_notes: project["seed_notes"],
          when_files_changed: project["when_files_changed"],
          captures: [], legacy_browser: true
        )
      end
    end

    private

    attr_reader :workspace_path, :changed_files, :preview_projects

    def config
      @config ||= SyrusYml.load_repo(workspace_path).visual_review
    rescue SyrusYml::ParseError, Errno::ENOENT
      nil
    end

    def configured_target(target)
      patterns = Array(target.when_files_changed)
      return if patterns.any? && changed_files.none? { |file| RepositoryContent::Glob.match?(patterns, file) }

      Target.new(
        name: target.name,
        provider: target.provider,
        workspace_path: workspace_path.to_s,
        launch: target.launch,
        build: target.build,
        dimensions: target.dimensions,
        review_notes: target.review_notes,
        when_files_changed: patterns,
        captures: target.captures,
        legacy_browser: false
      )
    end
  end
end
