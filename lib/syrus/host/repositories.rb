require "forwardable"

module Syrus
  module Host
    # Repository lookups scoped by access and archival state. Credentials,
    # synchronization, and persistence are not promised.
    module Repositories
      extend SingleForwardable

      def_delegators "::Repository", :where, :find, :find_by, :find_by!, :active, :accessible_to, :writable_by,
        :accessible_repository_ids_for, :arel_table, :create!
      def_delegator "::Repository", :new, :build
    end
  end
end
