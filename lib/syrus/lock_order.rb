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

    # NY40 (decided A): the order is moving to the hierarchy, parents before
    # children, with Lineage.lock! taking a record's ancestry first. Until every
    # entry point is converted, MODELS stays enforced and the target is
    # selectable for surveying: SYRUS_LOCK_ORDER_TARGET=hierarchical, or
    # LockOrder.target = :hierarchical in a spec.
    HIERARCHICAL = %w[ AppSetting User Epic Job WorkIntent WorkUnit Workflow Step Run ].freeze
    ORDERS = { current: MODELS, hierarchical: HIERARCHICAL }.freeze

    class << self
      def target
        @target ||= ENV["SYRUS_LOCK_ORDER_TARGET"] == "hierarchical" ? :hierarchical : :current
      end

      def target=(name)
        raise ArgumentError, "unknown lock order #{name.inspect}" unless ORDERS.key?(name.to_sym)

        @target = name.to_sym
      end

      def models = ORDERS.fetch(target)

      def ranks
        @ranks ||= {}
        @ranks[target] ||= models.each_with_index.to_h.freeze
      end
    end

    # `entry` is the outermost application frame: where the transaction's work
    # came in (a job's perform, a controller action, a service a spec called).
    Violation = Data.define(:held, :taking, :site, :held_site, :entry) do
      def initialize(held:, taking:, site:, held_site:, entry: nil)
        super
      end
    end

    # Inversions waiting on an operator decision (NY31): each is a lock site
    # pair the order cannot fix without a design choice. The checker records
    # them instead of raising; any other inversion fails the example.
    PENDING_DECISION = [
      # A Workflow cancelled from inside another Workflow's cancel (an
      # after_cancel hook, after the outer Workflow locked its Steps). The Job
      # closure path is pre-locked (NY33, JobClosure.lock_pending_workflows!);
      # only a hook-driven nested cancellation is left, and in the suite only a
      # spec stub does that.
      { held_site: "app/models/workflow.rb", site: "app/services/work_units/workflow_cancellation.rb" }
    ].freeze

    def self.pending_decision?(violation)
      PENDING_DECISION.any? do |pair|
        violation.held_site.to_s.start_with?("#{pair[:held_site]}:") && violation.site.to_s.start_with?("#{pair[:site]}:")
      end
    end
    class Error < StandardError; end

    def self.rank_for(model_class)
      ranks[model_class.base_class.name]
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
          ActiveRecord::Base.singleton_class.prepend(WriteTracking)
        end

        # Lead L14: an UPDATE or DELETE also takes an InnoDB exclusive lock on
        # every row it changes, held to commit. With SYRUS_LOCK_ORDER_WRITES=1
        # each row-level write (save, update_columns, destroy) counts as a
        # lock on that row, to survey how far the order covers what the code
        # really locks. Off by default; relation-wide update_all/delete_all are
        # not seen.
        def wrote(model_class, constraints)
          return unless ENV["SYRUS_LOCK_ORDER_WRITES"] == "1"

          key = model_class.primary_key
          id = constraints[key] || constraints[key.to_sym]
          return if id.nil? || id.is_a?(Array) || id.is_a?(Arel::Nodes::Node)

          observe(model_class, model_class.connection, ids: [ id ])
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
            report(Violation.new(held: held[:model], taking: model_class.base_class.name, site: site, held_site: held[:site],
                                entry: (mode == :record ? entry_site : nil)))
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
                         "#{violation.held} from #{violation.held_site} (order: #{LockOrder.models.join(' -> ')})"
          end
        end

        def entry_site
          location = caller_locations.reverse.find do |candidate|
            candidate.path.match?(%r{/(?:plugins/[^/]+/)?app/}) && !candidate.path.include?("/vendor/")
          end
          return fallback_site(:label) unless location

          "#{location.path.sub(%r{\A.*?/((?:plugins/[^/]+/)?app/)}, '\1')}:#{location.label}"
        end

        def site
          # The first application frame that is not a lock or reload wrapper.
          location = caller_locations.find do |candidate|
            candidate.path.match?(%r{/(?:plugins/[^/]+/)?app/}) && !candidate.path.include?("/vendor/") &&
              !candidate.label.to_s.match?(/\b(?:reload|lock!|with_lock)\z/)
          end
          return fallback_site(:lineno) unless location

          "#{location.path.sub(%r{\A.*?/((?:plugins/[^/]+/)?app/)}, '\1')}:#{location.lineno}"
        end

        # No application frame: the locks came from spec or library code (a
        # spec's own setup, a factory). Name its first frame so the record
        # says where to look.
        def fallback_site(detail)
          location = caller_locations.find do |candidate|
            candidate.path.match?(%r{/(?:plugins/[^/]+/)?(?:spec|lib)/}) && !candidate.path.include?("/vendor/") &&
              !candidate.path.end_with?("lib/syrus/lock_order.rb")
          end
          return "unknown" unless location

          "#{location.path.sub(%r{\A.*?/((?:plugins/[^/]+/)?(?:spec|lib)/)}, '\1')}:#{location.public_send(detail)}"
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

      module WriteTracking
        def _update_record(values, constraints)
          Checker.wrote(self, constraints)
          super
        end

        def _delete_record(constraints)
          Checker.wrote(self, constraints)
          super
        end
      end

      module RelationLock
        private

        # A NOWAIT lock fails at once instead of waiting (NY36), so it adds no
        # edge to the wait-for graph: outside the order, and not held.
        def exec_queries(...)
          records = super
          if lock_value && !(lock_value.is_a?(String) && lock_value.include?("NOWAIT"))
            Checker.observe(klass, klass.connection, ids: records.map(&:id))
          end
          records
        end
      end
    end
  end
end
