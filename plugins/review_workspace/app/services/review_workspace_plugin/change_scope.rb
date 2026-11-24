module ReviewWorkspacePlugin
  # Normalized change-scope aggregate for the mobile decision brief, read from
  # the stored canonical diff review version so the client never downloads the
  # diff. Returns nil when no stored diff exists; never guesses.
  class ChangeScope
    def self.call(job)
      version = Syrus::Host::DiffReviews.default_version_for_review(job)
      return nil unless version

      files = Array(version.files_snapshot).select { |file| file.is_a?(Hash) }
      {
        files_changed: files.size,
        additions: files.sum { |file| file["additions"].to_i },
        deletions: files.sum { |file| file["deletions"].to_i },
        truncated: version.truncated
      }
    end
  end
end
