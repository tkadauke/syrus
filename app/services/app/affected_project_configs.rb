module App
  class AffectedProjectConfigs
    def self.call(workspace_path:, changed_files:)
      new(workspace_path, changed_files: changed_files).call
    end

    def initialize(workspace_path, changed_files:)
      @workspace_path = Pathname.new(workspace_path)
      @changed_files = Array(changed_files).map(&:to_s)
    end

    def call
      projects = graph.affected_projects(changed_files: changed_files)

      result_for(projects.filter_map { |project| project_context(project) })
    rescue StandardError => e
      Rails.logger.warn("[#{self.class.name}] unavailable for #{workspace_path}: #{e.class}: #{e.message}")
      result_for([])
    end

    private

    attr_reader :workspace_path, :changed_files

    def graph
      @graph ||= TargetGraph::Compiler.compile(workspace_path)
    end

    def project_context(project)
      config = config_for(project)
      return nil unless config

      context_for(project, config)
    end

    def config_for(_project)
      raise NotImplementedError, "#{self.class.name} must implement #config_for"
    end

    def context_for(_project, _config)
      raise NotImplementedError, "#{self.class.name} must implement #context_for"
    end

    def result_for(_projects)
      raise NotImplementedError, "#{self.class.name} must implement #result_for"
    end
  end
end
