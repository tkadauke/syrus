module App
  # Resolves the project-scoped adversarial review criteria relevant to the
  # exact diff under review. Root criteria remain repo-wide; nested project
  # criteria are included only when the diff touches that project.
  class AdversarialReviewContext
    MAX_CHANGED_FILES = 200

    Project = Data.define(:id, :label, :path, :owner_config_path, :criteria) do
      def to_h
        {
          "id" => id,
          "label" => label,
          "path" => path,
          "owner_config_path" => owner_config_path,
          "criteria" => criteria
        }
      end
    end

    Result = Data.define(:projects, :criteria) do
      def to_h
        {
          "projects" => projects.map(&:to_h),
          "criteria" => criteria
        }
      end
    end

    def self.call(workspace_path:, diff:)
      new(workspace_path, diff: diff).call
    end

    def initialize(workspace_path, diff:)
      @workspace_path = Pathname.new(workspace_path)
      @diff = diff.to_s
    end

    def call
      projects = graph.projects.values.filter_map { |project| project_context(project) }
      return fallback_result if projects.empty?

      Result.new(projects: projects, criteria: dedupe(projects.flat_map(&:criteria)))
    rescue StandardError => e
      Rails.logger.warn("[App::AdversarialReviewContext] unavailable for #{workspace_path}: #{e.class}: #{e.message}")
      fallback_result
    end

    private

    attr_reader :workspace_path, :diff

    def graph
      @graph ||= TargetGraph::Compiler.compile(workspace_path)
    end

    def project_context(project)
      criteria = normalized_criteria(project.adversarial_review&.criteria)
      return nil if criteria.empty?
      return nil unless affected_project?(project)

      Project.new(
        id: project.id,
        label: project.label,
        path: project.path,
        owner_config_path: project.owner_config_path,
        criteria: criteria
      )
    end

    def affected_project?(project)
      return true if changed_files.empty?
      return true if project.path.blank?

      changed_files.any? { |file| file == project.path || file.start_with?("#{project.path}/") }
    end

    def changed_files
      @changed_files ||= diff.split(/(?=^diff --git )/)
        .first(MAX_CHANGED_FILES)
        .filter_map do |section|
          header = section.lines.first.to_s
          header[/\Adiff --git a\/.+ b\/(.+)\s*\z/, 1]
        end
    end

    def fallback_result
      criteria = normalized_criteria(SyrusYml.load_repo(workspace_path).adversarial_review&.criteria)
      project = if criteria.any?
        Project.new(
          id: TargetGraph::ROOT_PROJECT_ID,
          label: "Repository",
          path: "",
          owner_config_path: SyrusYml::CONFIG_FILE,
          criteria: criteria
        )
      end

      Result.new(projects: Array(project), criteria: criteria)
    rescue SyrusYml::ParseError, Errno::ENOENT
      Result.new(projects: [], criteria: [])
    end

    def normalized_criteria(criteria)
      Array(criteria).map(&:to_s).map(&:strip).reject(&:empty?)
    end

    def dedupe(criteria)
      seen = {}
      criteria.filter_map do |criterion|
        next if seen[criterion]

        seen[criterion] = true
        criterion
      end
    end
  end
end
