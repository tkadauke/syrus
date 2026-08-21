module Go
  # :dependency_audit_command for Go repositories: go.sum is the lockfile
  # signal (go.mod is the manifest :prepare_detector keys off, but doesn't
  # by itself reflect a resolved dependency version change).
  class DependencyAuditCommand
    def self.lockfiles
      [ "go.sum" ]
    end

    def self.audit_command(workspace_path:)
      return nil unless Pathname.new(workspace_path).join("go.sum").exist?

      "govulncheck ./..."
    end
  end
end
