module RepositoryContent
  # One path that differs between two revisions.
  #
  #   status         "added", "modified", "deleted", or "renamed"
  #   previous_path  the old path of a rename, nil otherwise
  #   patch          unified diff text when requested and available (nil for
  #                  binary or oversized files)
  CHANGE_STATUSES = %w[added modified deleted renamed].freeze

  Change = Data.define(:path, :status, :previous_path, :patch, :additions, :deletions) do
    def initialize(path:, status:, previous_path: nil, patch: nil, additions: nil, deletions: nil)
      raise ArgumentError, "unknown change status #{status.inspect}" unless CHANGE_STATUSES.include?(status)

      super
    end
  end
end
