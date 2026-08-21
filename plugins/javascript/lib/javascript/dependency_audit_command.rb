module JavaScript
  # :dependency_audit_command for Node/JS (and TS) repositories. Picks the
  # audit command matching whichever package manager's lockfile
  # :prepare_detector's own PRIORITY table found on disk — same three true
  # lockfiles (yarn.lock/pnpm-lock.yaml/package-lock.json), reusing that
  # table instead of re-deriving the list. `package.json` alone (the
  # detector's last-resort fallback, no lockfile) isn't audited: without a
  # lockfile there's no pinned dependency tree for the audit tool to check.
  class DependencyAuditCommand
    AUDIT_COMMANDS = {
      "yarn.lock"         => "yarn audit --json",
      "pnpm-lock.yaml"    => "pnpm audit --json",
      "package-lock.json" => "npm audit --json"
    }.freeze

    def self.lockfiles
      AUDIT_COMMANDS.keys
    end

    def self.audit_command(workspace_path:)
      path = Pathname.new(workspace_path)
      entry = AUDIT_COMMANDS.find { |file, _cmd| path.join(file).exist? }
      entry&.last
    end
  end
end
