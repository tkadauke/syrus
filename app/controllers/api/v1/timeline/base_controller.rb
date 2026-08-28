module Api
  module V1
    module Timeline
      # Shared base for the worker-activity-timeline plugin's read-only
      # data API. Gated the same way as the rest of the REST admin API
      # (Bearer-token auth + User#admin?) by inheriting Admin::BaseController
      # rather than reimplementing the check.
      class BaseController < Api::V1::Admin::BaseController
      end
    end
  end
end
