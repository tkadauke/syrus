module Syrus
  module Plugin
    module ReviewerTargetProvider
      extend ActiveSupport::Concern

      class_methods do
        def target_type = raise NotImplementedError
        def options(user:, repository: nil) = raise NotImplementedError
        def resolve(reference:, owner:, repository:) = raise NotImplementedError
        def available?(resolution:, owner:, repository:) = true
        def uniqueness_key(resolution:) = "#{target_type}:#{resolution.fetch(:reference)}"
        def audit_snapshot(resolution:) = resolution.fetch(:display)
      end
    end
  end
end
