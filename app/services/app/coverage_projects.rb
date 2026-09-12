module App
  # Resolves coverage plans from the checked-out workflow workspace. Root
  # coverage remains repository-wide for legacy repositories; nested coverage
  # applies only when the diff touches that owning project.
  class CoverageProjects
    Result = Data.define(:plans) do
      def any? = plans.any?
      def root_plan = plans.find(&:root_project?)
      def project_plans = plans.reject(&:root_project?)
    end

    def self.call(workspace_path:, changed_files:)
      new(workspace_path, changed_files: changed_files).call
    end

    def initialize(workspace_path, changed_files:)
      @workspace_path = Pathname.new(workspace_path)
      @changed_files = Array(changed_files).map(&:to_s)
    end

    def call
      Result.new(plans: graph.projects.values.filter_map { |project| plan_for(project) })
    rescue StandardError => e
      Rails.logger.warn("[App::CoverageProjects] unavailable for #{workspace_path}: #{e.class}: #{e.message}")
      Result.new(plans: [])
    end

    private

    attr_reader :workspace_path, :changed_files

    def graph
      @graph ||= TargetGraph::Compiler.compile(workspace_path)
    end

    def plan_for(project)
      return nil unless project.coverage
      return nil unless affected_project?(project)

      project.coverage.with_project(project)
    end

    def affected_project?(project)
      return true if project.root?
      return true if changed_files.empty?

      base_path = coverage_base_path(project)
      changed_files.any? { |file| file == base_path || file.start_with?("#{base_path}/") }
    end

    def coverage_base_path(project)
      File.dirname(project.owner_config_path.to_s)
    end
  end
end
