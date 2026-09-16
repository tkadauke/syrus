module Syrus
  module Metrics
    # A declared metric: what it is called, what shape it has, which dimensions
    # it may carry, who owns it, and whether telemetry may share it.
    #
    # `share` defaults to false. A metric leaves this install only if its
    # declaration says so, which puts the privacy decision in the diff where
    # review can see it.
    class Definition
      # Deliberately no Summary. Client-side quantiles cannot be aggregated
      # across processes -- there is no function of two pods' p99 values that
      # yields the combined p99, because quantiles are neither linear nor
      # weight-carrying -- which makes them useless in a multi-pod deployment.
      # Histograms aggregate because their buckets are counters, and counters
      # sum.
      TYPES = %i[counter gauge histogram].freeze

      attr_reader :name, :type, :tags, :comment, :owner, :share, :buckets, :sample_block

      def initialize(name:, type:, tags: [], comment: nil, owner: :core, share: false, buckets: nil, sample_block: nil)
        @name = name
        @type = type
        @tags = tags
        @comment = comment
        @owner = owner
        @share = share
        @buckets = buckets
        @sample_block = sample_block
      end

      def sampled? = sample_block.present?

      def validate!
        unless TYPES.include?(type)
          raise Error, "metric #{name}: unknown type #{type.inspect} (expected one of #{TYPES.join(', ')})"
        end
        if type == :histogram && buckets.blank?
          raise Error, "metric #{name}: histograms must declare buckets"
        end
        if type != :histogram && buckets
          raise Error, "metric #{name}: only histograms take buckets"
        end
        if sample_block && type != :gauge
          raise Error, "metric #{name}: only a gauge may declare a sample block " \
                       "(a counter/histogram needs cursor-based cumulative logic -- use `sampler <class>` instead)"
        end
        if sample_block && tags.present?
          raise Error, "metric #{name}: a sampled gauge block does not support tags -- " \
                       "declare a full sampler class with `sampler <class>` for tagged output"
        end

        TagAllowlist.validate!(name: name, tags: tags)
        self
      end

      def core? = owner.to_s == "core"
      def shared? = share.present?

      def to_catalog_row
        {
          "name" => name.to_s,
          "type" => type.to_s,
          "tags" => tags.map(&:to_s),
          "owner" => owner.to_s,
          "shared" => shared?,
          "comment" => comment.to_s
        }
      end
    end
  end
end
