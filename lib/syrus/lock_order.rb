require "set"

module Syrus
  # The global row-lock order (NY25). A transaction that holds row locks on
  # several of these models must take them in this order, so two transactions
  # can never each wait on a lock the other holds (formal/SyrusModel/LockOrder.lean).
  # Locks on the same model are unordered among themselves; models not listed
  # are outside the order.
  module LockOrder
    MODELS = %w[ AppSetting Epic Run Job WorkIntent Workflow Step WorkUnit User ].freeze
    RANKS = MODELS.each_with_index.to_h.freeze

    Violation = Data.define(:held, :taking, :site, :held_site)

    # Inversions waiting on an operator decision (NY31): each is a lock site
    # pair the order cannot fix without a design choice. The checker records
    # them instead of raising; any other inversion fails the example.
    PENDING_DECISION = [
      # Provider-account reservation locks the User row as a mutex mid-transaction.
      { held_site: "app/services/provider_routing/availability_selector.rb", site: "app/services/step_dispatcher.rb" },
      # The same reservation, then a base-refresh retry records itself on its
      # source Workflow (set_artifact!). Part of NY35.
      { held_site: "app/services/provider_routing/availability_selector.rb", site: "app/models/workflow.rb" },
      # Cancelling a Workflow cascades to its descendants: A, A's Steps, then B.
      { held_site: "app/models/workflow.rb", site: "app/services/work_units/workflow_cancellation.rb" }
    ].freeze

    def self.pending_decision?(violation)
      PENDING_DECISION.any? do |pair|
        violation.held_site.to_s.start_with?("#{pair[:held_site]}:") && violation.site.to_s.start_with?("#{pair[:site]}:")
      end
    end
    class Error < StandardError; end

    def self.rank_for(model_class)
      RANKS[model_class.base_class.name]
    rescue NoMethodError
      nil
    end

    # Test-mode checker. Inside the application's outermost transaction it
    # remembers the highest-ranked model locked so far and reports a lock on
    # a lower-ranked one. `mode` is :raise (the default in the test suite) or
    # :record, which collects violations in `violations` instead.
    module Checker
      class << self
        attr_accessor :mode

        def violations = (@violations ||= [])

        def reset!
          @violations = []
          Thread.current[:syrus_lock_order_state] = nil
          Thread.current[:syrus_lock_order_created] = nil
        end

        def install!
          # lock! and with_lock reload through a locking relation query, so
          # this one hook sees every row lock the application takes.
          ActiveRecord::Relation.prepend(RelationLock)
          ActiveRecord::Base.prepend(CreateTracking)
        end

        # A row the transaction inserted is invisible to every other
        # transaction until commit, so locking it never waits and nobody else
        # can be waiting on it: it is outside the order. Restarting a Job
        # closes the old one and launches the replacement in one transaction,
        # locking the old WorkUnit and then the Workflow it just created.
        def created(record)
          rank = LockOrder.rank_for(record.class)
          return unless rank

          root = application_transaction(record.class.connection)
          return unless root

          state = (Thread.current[:syrus_lock_order_created] ||= {})
          entry = state[record.class.connection.object_id]
          entry = nil unless entry && entry[:transaction].equal?(root)
          entry ||= (state[record.class.connection.object_id] = { transaction: root, rows: Set.new })
          entry[:rows] << [ record.class.base_class.name, record.id ]
        end

        # `ids` are the rows the locking query returned. A row the
        # transaction already holds can be locked again in any order.
        def observe(model_class, connection, ids: [])
          rank = LockOrder.rank_for(model_class)
          return unless rank

          root = application_transaction(connection)
          return unless root

          # One entry per connection, for the transaction it belongs to: a
          # finished transaction's entry is discarded the first time another
          # transaction on that connection locks something.
          state = (Thread.current[:syrus_lock_order_state] ||= {})
          held = state[connection.object_id]
          held = nil unless held && held[:transaction].equal?(root)
          rows = ids.map { |id| [ model_class.base_class.name, id ] }
          return if rows.any? && rows.all? { |row| created_in?(connection, root, row) }
          relock = held && rows.any? && rows.all? { |row| held[:rows].include?(row) }
          held[:rows].merge(rows) if held
          if held && held[:rank] > rank && !relock
            report(Violation.new(held: held[:model], taking: model_class.base_class.name, site: site, held_site: held[:site]))
          end
          return if held && rank <= held[:rank]

          state[connection.object_id] = { transaction: root, rank: rank, model: model_class.base_class.name, site: site,
                                          rows: (held ? held[:rows] : Set.new).merge(rows) }
        end

        private

        def created_in?(connection, root, row)
          entry = (Thread.current[:syrus_lock_order_created] || {})[connection.object_id]
          entry && entry[:transaction].equal?(root) && entry[:rows].include?(row)
        end

        # The first joinable transaction: a transactional test wraps each
        # example in a non-joinable one that is not the application's.
        def application_transaction(connection)
          stack = connection.transaction_manager.instance_variable_get(:@stack) || []
          stack.find(&:joinable?)
        end

        def report(violation)
          if mode == :record || LockOrder.pending_decision?(violation)
            violations << violation
          else
            raise Error, "row lock order violated: took #{violation.taking} at #{violation.site} while holding " \
                         "#{violation.held} from #{violation.held_site} (order: #{MODELS.join(' -> ')})"
          end
        end

        def site
          # The first application frame that is not a lock or reload wrapper.
          location = caller_locations.find do |candidate|
            candidate.path.match?(%r{/(?:plugins/[^/]+/)?app/}) && !candidate.path.include?("/vendor/") &&
              !candidate.label.to_s.match?(/\b(?:reload|lock!|with_lock)\z/)
          end
          return "unknown" unless location

          "#{location.path.sub(%r{\A.*?/((?:plugins/[^/]+/)?app/)}, '\1')}:#{location.lineno}"
        end
      end

      module CreateTracking
        private

        def _create_record(...)
          result = super
          Checker.created(self)
          result
        end
      end

      module RelationLock
        private

        def exec_queries(...)
          records = super
          Checker.observe(klass, klass.connection, ids: records.map(&:id)) if lock_value
          records
        end
      end
    end
  end
end
