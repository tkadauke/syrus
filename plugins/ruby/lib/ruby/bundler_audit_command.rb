module Ruby
  # :dependency_audit_command for plain Ruby repositories: Gemfile.lock is
  # the lockfile that reflects an actual dependency version change (Gemfile
  # alone, which :prepare_detector keys off, only reflects declared
  # constraints). Gated on Gemfile.lock's presence, mirroring
  # RubocopAutofix's own config-signal gate.
  class BundlerAuditCommand
    def self.lockfiles
      [ "Gemfile.lock" ]
    end

    def self.audit_command(workspace_path:)
      return nil unless Pathname.new(workspace_path).join("Gemfile.lock").exist?

      "bundle-audit check --update"
    end
  end
end
