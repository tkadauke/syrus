module App
  class CoworkerReviewProjects < AdversarialReviewProjects
    private

    def config_for(project)
      project.coworker_review
    end
  end
end
