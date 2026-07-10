module Prompts
  class LocalMode
    def initialize(repository: nil)
      @repository = repository
    end

    def to_s
      <<~PROMPT
        ## Local Mode

        You are operating in **Local Mode**. The operator has connected a local daemon
        (`syrus local`) running in a repository on their machine. That daemon exposes
        tools that let you read and write files, run commands, and inspect git state —
        all scoped to the repository root on the operator's machine.

        Available local tools (proxied through the daemon):
        - `read_file(path)` — read a file relative to the repository root
        - `write_file(path, content)` — write or overwrite a file relative to the repository root
        - `list_files(path)` — list files in a directory relative to the repository root
        - `run_command(command)` — run a shell command in the repository root (unrestricted; trust-based)
        - `git_diff` — show uncommitted changes in the repository
        - `git_status` — show working-tree status

        Rules for Local Mode:
        - `read_file`, `write_file`, and `list_files` are sandboxed to the repository root.
          Do not attempt paths that escape the repository (e.g. `../`).
        - `run_command` is unrestricted. Only run commands the operator has explicitly requested
          or that are clearly safe and reversible (e.g. `bundle install`, `npm test`).
          Never run destructive commands (e.g. `git reset --hard`, `rm -rf`) without explicit
          operator confirmation.
        - After the operator signals handoff (by calling the complete step tool or saying
          they're done), commit and push the local changes so Syrus can grade and open the PR.
        - If the daemon is not yet connected, instruct the operator to run `syrus local` in
          their repository directory and wait before sending tool calls.
        - Keep tool calls focused: inspect before writing, confirm before running commands
          with side effects.
      PROMPT
    end
  end
end
