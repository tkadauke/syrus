class JobDependency
  module SatisfactionModes
    MODES = {
      "success" => "JobDependency::SatisfactionModes::Success",
      "closed" => "JobDependency::SatisfactionModes::Closed",
      "deployment_stage" => "JobDependency::SatisfactionModes::DeploymentStage"
    }.freeze

    def self.for(dependency)
      MODES.fetch(dependency.satisfaction_mode).constantize.new(dependency)
    end
  end
end
