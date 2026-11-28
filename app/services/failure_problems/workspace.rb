module FailureProblems
  # Classifies a step that failed because its workflow workspace directory is
  # gone. ProcessRunner spawns every subprocess with `chdir:` the workspace
  # root, so when the directory vanished underneath a running workflow (its
  # worker was replaced, storage was reclaimed) the spawn itself raises
  # Errno::ENOENT naming that root -- and a grader that never got to run ends
  # inconclusive with no exit status. That is infrastructure, not the change:
  # a fresh workflow recreates the workspace.
  #
  # Only the workspace *root* counts. ENOENT on a path inside the workspace
  # (a file the change deleted, a script it forgot to add) is exactly the
  # kind of failure the change can cause, so it makes no claim.
  module Workspace
    module_function

    ROOT_PATTERN = %r{No such file or directory(?: @ \w+)? - (\S*/workflows/(\d+))/?\z}

    def for_enoent(error)
      root, workflow_id = workflow_root(error.message)
      return nil unless root
      # Decided where it happened: on the worker that raised, the directory
      # is either there or not.
      return nil if File.directory?(root)

      FailureProblems.declare(:workspace_lost, workflow_id: workflow_id.to_i, workspace_path: root)
    end

    # [root, workflow_id] when an ENOENT message names a workflow workspace
    # root itself, else nil. Shared with RunFailureClassifier's fallback for
    # rows recorded before the code was declared here.
    def workflow_root(message)
      match = message.to_s.strip.match(ROOT_PATTERN)
      match && [ match[1], match[2] ]
    end
  end
end
