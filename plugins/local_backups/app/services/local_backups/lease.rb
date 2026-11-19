module LocalBackups
  class Lease
    class Busy < StandardError; end

    def initialize(root:)
      @path = root.path.join(".creation.lock")
    end

    def synchronize
      File.open(@path, File::RDWR | File::CREAT, 0o600) do |file|
        raise Busy, "another local backup is already being created" unless file.flock(File::LOCK_EX | File::LOCK_NB)

        yield
      ensure
        file.flock(File::LOCK_UN) rescue nil
      end
    end
  end
end
