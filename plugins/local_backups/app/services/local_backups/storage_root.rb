module LocalBackups
  class StorageRoot
    class Invalid < StandardError; end

    attr_reader :path

    def initialize(configured: ENV["SYRUS_BACKUP_ROOT"], data_root: ENV["SYRUS_DATA_ROOT"])
      raise Invalid, "SYRUS_BACKUP_ROOT is not configured" if configured.blank?

      candidate = Pathname.new(configured)
      raise Invalid, "SYRUS_BACKUP_ROOT must be absolute" unless candidate.absolute?

      @path = candidate.cleanpath
      reject_symlink_components!
      @path = @path.realpath
      reject_primary_data_nesting!(data_root)
    rescue Errno::ENOENT
      raise Invalid, "SYRUS_BACKUP_ROOT must exist"
    end

    def contained(relative)
      relative_path = Pathname.new(relative.to_s)
      raise Invalid, "artifact path must be relative" if relative_path.absolute?

      clean = relative_path.cleanpath
      raise Invalid, "artifact path escapes backup root" if clean.each_filename.first == ".."

      candidate = path.join(clean)
      resolved = candidate.realpath
      raise Invalid, "artifact path escapes backup root" unless inside?(resolved, path)

      resolved
    rescue Errno::ENOENT
      raise Invalid, "artifact path does not exist"
    end

    private

    def reject_symlink_components!
      current = Pathname.new(File::SEPARATOR)
      path.each_filename do |part|
        current = current.join(part)
        raise Invalid, "SYRUS_BACKUP_ROOT may not contain symlinks" if current.symlink?
      end
    end

    def reject_primary_data_nesting!(data_root)
      return if data_root.blank?

      data = Pathname.new(data_root).realpath
      if inside?(path, data) || inside?(data, path)
        raise Invalid, "backup and primary data roots may not contain one another"
      end
    rescue Errno::ENOENT
      nil
    end

    def inside?(candidate, parent)
      candidate == parent || candidate.to_s.start_with?("#{parent}#{File::SEPARATOR}")
    end
  end
end
