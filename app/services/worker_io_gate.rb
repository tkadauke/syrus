class WorkerIoGate
  def self.synchronize
    lock_path = WorkflowWorkspace.data_root.join("locks", "worker-archive-io.lock")
    FileUtils.mkdir_p(lock_path.dirname)

    File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    ensure
      lock.flock(File::LOCK_UN) rescue nil
    end
  end
end
