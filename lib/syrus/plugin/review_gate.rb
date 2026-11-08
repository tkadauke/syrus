module Syrus
  module Plugin
    # Contract for a review loop contributed to a host workflow. Providers
    # return one or more hashes from `.review_gates`; the host owns ordering
    # and loop mechanics while the provider owns enablement and execution
    # metadata.
    module ReviewGate
      SLOTS = %w[after_agent].freeze

      def self.included(base) = base.extend(ClassMethods)

      module ClassMethods
        def review_gates = []

        # Extra Job-detail payload fields (Symbol keys) this gate's owner
        # exposes about its effective configuration for `job`.
        def job_detail_fields(job) = {}
      end
    end
  end
end
