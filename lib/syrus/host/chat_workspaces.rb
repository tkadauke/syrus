require "forwardable"

module Syrus
  module Host
    # Path and git-state helpers for chat workspaces.
    module ChatWorkspaces
      extend SingleForwardable

      def_delegators "::ChatWorkspace", :repo_path_for, :ensure_root!, :rebase_in_progress?, :uncommitted_changes?
    end
  end
end
