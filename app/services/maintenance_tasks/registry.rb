module MaintenanceTasks
  class Registry
    class << self
      def definitions
        @definitions ||= [
          Definitions::AgentsBackfill.new
        ].index_by(&:key)
      end

      def all
        definitions.values
      end

      def fetch(key)
        definitions.fetch(key.to_s)
      end
    end
  end
end
