module Coworkers
  class OwnerResolver
    def initialize(owner:)
      @owner = owner
    end

    def scope
      Coworkers::Coworker.where(owner_user: owner)
    end

    def find!(id: nil, handle: nil)
      raise ArgumentError, "provide exactly one of coworker_id or handle" if id.present? == handle.present?

      normalized_handle = HandleRegistry.normalize(handle).delete_prefix("@")
      id.present? ? scope.find(id) : scope.find_by!("LOWER(handle) = ?", normalized_handle)
    end

    private

    attr_reader :owner
  end
end
