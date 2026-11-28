module Coworkers
  # Captures one coherent immutable activation for turn admission. Taking the
  # same row lock as publication gives concurrent resolution a total database
  # order: a turn sees either the complete prior activation or the complete
  # replacement, never a mixed pointer set.
  class EnvironmentActiveSelection
    InconsistentPointer = Class.new(StandardError)
    Selection = Data.define(:activation_id, :revision_id, :runtime_image_id, :image_digest, :runtime_image)

    def self.resolve(environment) = new(environment).resolve

    def initialize(environment)
      @environment = environment
    end

    def resolve
      environment.with_lock do
        environment.reload
        activation = environment.active_activation
        return unless activation

        unless activation.runtime_image.pullable?
          raise InconsistentPointer, I18n.t("api.coworkers.environment_inconsistent_activation")
        end

        unless activation.environment_revision_id == environment.active_revision_id &&
            activation.runtime_image_id == environment.active_runtime_image_id &&
            activation.image_digest == activation.runtime_image.digest
          raise InconsistentPointer, I18n.t("api.coworkers.environment_inconsistent_activation")
        end

        Selection.new(activation_id: activation.id, revision_id: activation.environment_revision_id,
                      runtime_image_id: activation.runtime_image_id, image_digest: activation.image_digest,
                      runtime_image: activation.runtime_image)
      end
    end

    private

    attr_reader :environment
  end
end
