module LocalBackups
  class CapacityAdmission
    DEFAULT_ABSOLUTE_RESERVE = 1.gigabyte
    DEFAULT_PERCENT_RESERVE = 10
    # Until real bundle history exists, reserve a second bundle-sized staging
    # allowance in addition to the database snapshot and safety reserve.
    CONSTRUCTION_OVERHEAD_PERCENT = 100

    class InsufficientSpace < StandardError
      attr_reader :required_bytes, :available_bytes

      def initialize(required_bytes:, available_bytes:)
        @required_bytes = required_bytes
        @available_bytes = available_bytes
        super("backup requires #{required_bytes} bytes but only #{available_bytes} are available")
      end
    end

    def initialize(root:, available_bytes: nil, capacity_bytes: nil,
      absolute_reserve: ENV.fetch("SYRUS_BACKUP_MIN_FREE_BYTES", DEFAULT_ABSOLUTE_RESERVE).to_i,
      percent_reserve: ENV.fetch("SYRUS_BACKUP_MIN_FREE_PERCENT", DEFAULT_PERCENT_RESERVE).to_f)
      @root = root
      @available_bytes = available_bytes
      @capacity_bytes = capacity_bytes
      @absolute_reserve = absolute_reserve
      @percent_reserve = percent_reserve
    end

    def admit!(database_bytes:, blob_bytes:)
      sealed = estimated_sealed_bytes(database_bytes:, blob_bytes:)
      overhead = (sealed * CONSTRUCTION_OVERHEAD_PERCENT / 100.0).ceil
      reserve = [@absolute_reserve, (capacity_bytes * @percent_reserve / 100.0).ceil].max
      required = sealed + database_bytes + overhead + reserve
      available = available_bytes
      raise InsufficientSpace.new(required_bytes: required, available_bytes: available) if available < required

      required
    end

    private

    def estimated_sealed_bytes(database_bytes:, blob_bytes:)
      recent = Backup.where(state: "completed").where("stored_bytes > 0")
        .order(completed_at: :desc).limit(3).pluck(:stored_bytes).max
      [recent.to_i, database_bytes + blob_bytes].max
    end

    def filesystem
      @filesystem ||= DataRootDiskUsage.read(@root.path) || raise("backup filesystem capacity is unavailable")
    end

    def available_bytes
      @available_bytes || filesystem.available_bytes
    end

    def capacity_bytes
      @capacity_bytes || filesystem.total_bytes
    end
  end
end
