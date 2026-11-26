require "forwardable"

module Syrus
  module Host
    # Job queries for plugins that list, rank, or count Jobs. Every method
    # returns a relation or a plain value; Job persistence, transitions, and
    # callbacks are not promised.
    module Jobs
      extend SingleForwardable

      def_delegators "::Job", :all, :none, :where, :find, :find_by, :create!, :transaction,
        :visible_to, :open_threads, :priority_rank

      def self.user_facing_kinds = ::Job::Kind.user_facing_values

      def self.terminal_states = ::Job::TERMINAL_STATES
    end
  end
end
