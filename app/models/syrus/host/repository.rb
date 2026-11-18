module Syrus
  module Host
    class Repository < ReadFacade
      wraps ::Repository

      class << self
        def active = wrap_all(record_class.active)
        def accessible_to(user) = wrap_all(record_class.where(id: record_class.accessible_repository_ids_for(user)))
        def writable_by(user) = wrap_all(record_class.writable_by(user))
      end

      def id = read(:id)
      def owner = read(:owner)
      def name = read(:name)
      def archived_at = read(:archived_at)
      def jobs = Job.wrap_all(read(:jobs))
    end
  end
end
