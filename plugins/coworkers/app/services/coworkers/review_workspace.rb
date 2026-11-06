require "fileutils"

class Coworkers::ReviewWorkspace
  UnsafePath = Class.new(StandardError)

  class << self
    def path_for(run)
      root_for(run).join(run.id.to_s)
    end

    def remove!(context)
      stored = Pathname(context.workspace_path).cleanpath
      expected = path_for(context.run).cleanpath
      raise UnsafePath, "review workspace path does not belong to its Run" unless stored == expected
      return unless stored.exist? || stored.symlink?
      raise UnsafePath, "review workspace path must not be a symlink" if stored.symlink?

      root = root_for(context.run)
      raise UnsafePath, "review workspace root is unavailable" unless root.directory?
      raise UnsafePath, "review workspace escaped its root" unless stored.realpath.parent == root.realpath

      FileUtils.remove_entry_secure(stored.to_s)
    end

    private

    def root_for(run)
      WorkflowWorkspace.new(run.workflow).path.dirname.join("coworker-review-workspaces")
    end
  end
end
