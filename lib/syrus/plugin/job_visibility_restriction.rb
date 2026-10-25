module Syrus
  module Plugin
    # Restricts user-facing visibility for every Job created by one origin.
    # Core combines the returned origin ids with repository visibility; a
    # provider never receives or rewrites the surrounding Job relation.
    module JobVisibilityRestriction
      def self.included(base) = base.extend(self)

      def origin_key = raise(NotImplementedError, "#{self} must define .origin_key")

      # Return origin_id values visible to +user+. A relation selecting one
      # column is preferred for large sets; an Array is also accepted.
      def visible_origin_ids(user:) = raise(NotImplementedError, "#{self} must define .visible_origin_ids")
    end
  end
end
