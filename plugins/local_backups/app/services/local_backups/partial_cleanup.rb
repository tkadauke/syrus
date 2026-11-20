module LocalBackups
  class PartialCleanup
    def initialize(root: StorageRoot.new, older_than: ENV.fetch("SYRUS_BACKUP_PARTIAL_RETENTION_HOURS", 48).to_i.hours.ago)
      @root, @older_than = root, older_than
    end

    def call
      removed = 0
      @root.path.children.select { |path| path.basename.to_s.end_with?(".partial") && path.mtime < @older_than }.each do |path|
        next unless path.parent.realpath == @root.path
        FileUtils.remove_entry_secure(path)
        removed += 1
      end
      OperationalEvents.emit("partials_cleaned", removed:) if removed.positive?
      removed
    end
  end
end
