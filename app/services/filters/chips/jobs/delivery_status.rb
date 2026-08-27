module Filters
  module Chips
    module Jobs
      # Filters by `DeliveryStatus.for(job:)` (see app/services/delivery_status.rb
      # and config/syrus_docs/delivery_tracks.md) — the same apparent-delivery-
      # status summary the Job detail page and this chip's dashboard smart
      # folders read. Unlike most chips this can't compile to a single SQL
      # predicate: the status depends on `DeliveryPolicy` (repository-level
      # `.syrus.yml` config, not a DB column) as well as each Job's state and
      # `JobPrLink` rows. Evaluated in Ruby over the already-scoped candidate
      # set, memoizing one `DeliveryPolicy` per repository so a dashboard page
      # with many jobs across few repositories only reads `.syrus.yml` once
      # per repository, not once per Job.
      class DeliveryStatus < Base
        filter_name "delivery_status"
        label "Delivery status"
        bucket :enum
        operators :is, :is_one_of
        values(*::DeliveryStatus::STATUSES)

        def apply
          statuses = Array(value).map(&:to_s) & ::DeliveryStatus::STATUSES.map(&:to_s)
          return scope.none if statuses.empty?

          case op
          when :is, :is_one_of
            scope.where(id: matching_ids(statuses))
          else
            unsupported_op!
          end
        end

        private

        def matching_ids(statuses)
          scope.includes(:pr_links).find_each.select do |job|
            statuses.include?(::DeliveryStatus.for(job: job, policy: policy_for(job.repository_id)).to_s)
          end.map(&:id)
        end

        def policy_for(repository_id)
          @policy_cache ||= {}
          @policy_cache[repository_id] ||= DeliveryPolicy.for(repository: Repository.find(repository_id))
        end
      end
    end
  end
end
