module Coworkers
  # Aggregates coworker review criteria from the projects a change touches.
  # A project contributes only the configuration it owns: configuration a
  # nested project merely inherited from the root project is the root's own
  # contribution and is reported once, by the root project.
  class ReviewProjects < App::AdversarialReviewProjects
    private

    def config_for(project)
      configuration = project.plugin_configurations[Coworkers::ReviewPlan::KEY]
      return nil unless configuration
      return configuration if project.root?

      root = graph.root_project&.plugin_configurations&.[](Coworkers::ReviewPlan::KEY)
      configuration.equal?(root) ? nil : configuration
    end
  end
end
