module App
  class ReviewNoteProjects < AffectedProjectConfigs
    Project = Data.define(:id, :label, :path, :owner_config_path, :criteria, :low_signal) do
      def to_h
        {
          "id" => id,
          "label" => label,
          "path" => path,
          "owner_config_path" => owner_config_path,
          "criteria" => criteria,
          "low_signal" => low_signal
        }
      end
    end

    Result = Data.define(:projects) do
      def to_a = projects.map(&:to_h)
      def criteria = projects.flat_map(&:criteria).uniq
      def low_signal = projects.flat_map(&:low_signal).uniq
      def empty? = criteria.empty? && low_signal.empty?
    end

    private

    def config_for(project)
      project.review_notes
    end

    def context_for(project, config)
      criteria = Array(config.criteria).map(&:to_s).map(&:strip).reject(&:empty?)
      low_signal = Array(config.low_signal).map(&:to_s).map(&:strip).reject(&:empty?)
      return nil if criteria.empty? && low_signal.empty?

      Project.new(
        id: project.id,
        label: project.label,
        path: project.path,
        owner_config_path: project.owner_config_path,
        criteria: criteria,
        low_signal: low_signal
      )
    end

    def result_for(projects)
      Result.new(projects: projects)
    end
  end
end
