module WorkIntents
  # Resolves the Job(s) a WorkIntent's scope_type ("job" / "epic" /
  # "repository") refers to. Centralizes per-scope-type behavior that used
  # to be duplicated as `case intent.scope_type` chains in
  # WorkIntents::Gates::Approval and WorkUnits::Launcher.
  module Scope
    class ConfigurationError < StandardError; end

    REGISTRY = {
      "job"        => "WorkIntents::Scopes::JobScope",
      "epic"       => "WorkIntents::Scopes::EpicScope",
      "repository" => "WorkIntents::Scopes::RepositoryScope"
    }.freeze

    def self.for(intent)
      class_name = REGISTRY[intent.scope_type.to_s]
      unless class_name
        raise ConfigurationError, "Unknown WorkIntent scope_type: #{intent.scope_type.inspect}"
      end

      class_name.constantize.new(intent)
    end
  end
end
