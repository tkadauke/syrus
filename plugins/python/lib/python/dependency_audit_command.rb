module Python
  # :dependency_audit_command for Python repositories. `pip-audit` inspects
  # the resolved environment/requirements directly, so unlike JavaScript's
  # per-package-manager split, one tool covers every Python lockfile flavor
  # :prepare_detector recognizes — gated on the same lockfile signals minus
  # bare `pyproject.toml` (a manifest with no pinned versions, nothing for
  # an audit tool to check).
  class DependencyAuditCommand
    LOCKFILES = [ "uv.lock", "poetry.lock", "requirements.txt" ].freeze

    def self.lockfiles
      LOCKFILES
    end

    def self.audit_command(workspace_path:)
      path = Pathname.new(workspace_path)
      return nil unless LOCKFILES.any? { |file| path.join(file).exist? }

      "pip-audit"
    end
  end
end
