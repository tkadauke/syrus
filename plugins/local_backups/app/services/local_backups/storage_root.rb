module LocalBackups
  class StorageRoot
    Error = Class.new(StandardError)

    attr_reader :path

    def self.from_env(env = ENV)
      new(env["SYRUS_BACKUP_ROOT"], data_root: env["SYRUS_DATA_ROOT"])
    end

    def initialize(value, data_root: nil)
      raise Error, "SYRUS_BACKUP_ROOT is not configured" if value.blank?

      @path = Pathname(value)
      raise Error, "SYRUS_BACKUP_ROOT must be absolute" unless path.absolute?
      raise Error, "SYRUS_BACKUP_ROOT must exist and be a directory" unless path.directory?
      reject_symlink_components!
      @path = path.realpath
      reject_unsafe_nesting!(data_root) if data_root.present?
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Error, e.message
    end

    def contain!(candidate)
      candidate = Pathname(candidate)
      resolved = candidate.realpath
      prefix = "#{path}#{File::SEPARATOR}"
      raise Error, "path escapes SYRUS_BACKUP_ROOT" unless resolved.to_s.start_with?(prefix)
      raise Error, "symlinks are not allowed below SYRUS_BACKUP_ROOT" if symlink_between?(path, candidate)

      resolved
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Error, e.message
    end

    private

    def reject_symlink_components!
      current = Pathname(File::SEPARATOR)
      path.each_filename do |part|
        current = current.join(part)
        raise Error, "SYRUS_BACKUP_ROOT may not contain symlinks" if current.symlink?
      end
    end

    def reject_unsafe_nesting!(data_root)
      data = Pathname(data_root)
      return unless data.absolute? && data.exist?

      data = data.realpath.to_s
      backup = path.to_s
      if backup == data || backup.start_with?("#{data}#{File::SEPARATOR}") || data.start_with?("#{backup}#{File::SEPARATOR}")
        raise Error, "SYRUS_BACKUP_ROOT and SYRUS_DATA_ROOT may not be nested"
      end
    end

    def symlink_between?(root, candidate)
      relative = candidate.expand_path.relative_path_from(root)
      current = root
      relative.each_filename.any? do |part|
        current = current.join(part)
        current.symlink?
      end
    rescue ArgumentError
      true
    end
  end
end
