module Syrus
  module Host
    class ReadFacade
      class << self
        attr_reader :record_class

        def wraps(record_class)
          @record_class = record_class
        end

        def find(id)
          new(record_class.find(id))
        end

        def wrap(record)
          new(record) if record
        end

        def wrap_all(records)
          records.map { |record| new(record) }
        end
      end

      def initialize(record)
        @record = record
      end

      private

      attr_reader :record

      def read(name)
        record.public_send(name)
      end
    end
  end
end
