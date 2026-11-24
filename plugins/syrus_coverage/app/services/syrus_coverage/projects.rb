module SyrusCoverage
  # Resolves coverage plans from the checked-out workflow workspace. Root
  # coverage remains repository-wide for legacy repositories; nested coverage
  # applies only when the diff touches that owning project.
  class Projects
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
      root_configuration = graph.root_project.plugin_configurations[KEY]
      Result.new(plans: graph.projects.values.filter_map { |project| plan_for(project, root_configuration) })
    rescue StandardError => e
      Rails.logger.warn("[SyrusCoverage::Projects] unavailable for #{workspace_path}: #{e.class}: #{e.message}")
      Result.new(plans: [])
    end

    private

    KEY = SyrusCoverage::RepositoryConfiguration::KEY

    attr_reader :workspace_path, :changed_files

    def graph
      @graph ||= Syrus::Host::TargetGraphCompiler.compile(workspace_path)
    end

    # The graph overlays the root's plugin configuration onto every nested
    # project, so a nested project without its own block holds the root's very
    # object. That is not a nested plan: the root plan already covers it.
    def plan_for(project, root_configuration)
      plan = project.plugin_configurations[KEY]
      return nil unless plan
      return nil if !project.root? && plan.equal?(root_configuration)
      return nil unless affected_project?(project)

      plan.with_project(project)
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
