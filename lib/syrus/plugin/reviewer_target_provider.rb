module Syrus
  module Plugin
    module ReviewerTargetProvider
      extend ActiveSupport::Concern

      class_methods do
        def target_type = raise NotImplementedError
        def options(user:, repository: nil) = raise NotImplementedError
        def resolve(reference:, owner:, repository:) = raise NotImplementedError
      end
    end
  end
end
