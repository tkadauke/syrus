module App
  module Presentation
    module PendingActions
      class Base
        def self.action_key(*keys)
          keys.each { |key| PendingActions.register(key, self) }
        end

        def initialize(action)
          @action = action
        end

        def label
          raise NotImplementedError
        end

        def detail
          nil
        end

        private

        attr_reader :action

        def key
          PendingActions.key_for(action)
        end

        def payload
          @payload ||= action.payload.to_h
        end

        def job_slug(id = payload["job_id"])
          App::Presentation.job_slug(id)
        end
      end
    end
  end
end
