module App
  # Resolves adversarial review criteria from the checked-out workflow
  # workspace, preserving root criteria as repo-wide while adding nested
  # project criteria only when that project is touched by the diff under
  # review.
  class AdversarialReviewProjects
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

    Result = Data.define(:projects) do
      def to_a = projects.map(&:to_h)
      def criteria = projects.flat_map(&:criteria).uniq
    end

    def self.call(workspace_path:, changed_files:)
      new(workspace_path, changed_files: changed_files).call
    end

    def initialize(workspace_path, changed_files:)
      @workspace_path = Pathname.new(workspace_path)
      @changed_files = Array(changed_files).map(&:to_s)
    end

    def call
      Result.new(projects: graph.projects.values.filter_map { |project| project_context(project) })
    rescue StandardError => e
      Rails.logger.warn("[App::AdversarialReviewProjects] unavailable for #{workspace_path}: #{e.class}: #{e.message}")
      Result.new(projects: [])
    end

    private

    attr_reader :workspace_path, :changed_files

    def graph
      @graph ||= TargetGraph::Compiler.compile(workspace_path)
    end

    def project_context(project)
      criteria = Array(project.adversarial_review&.criteria).map(&:to_s).map(&:strip).reject(&:empty?)
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
      return true if project.root?
      return true if changed_files.empty?

      changed_files.any? { |file| file == project.path || file.start_with?("#{project.path}/") }
    end
  end
end
