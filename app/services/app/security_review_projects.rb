module App
  class SecurityReviewProjects < AdversarialReviewProjects
    private

    def config_for(project)
      project.security_review
    end
  end
end
