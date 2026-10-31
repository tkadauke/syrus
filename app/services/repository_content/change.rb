module RepositoryContent
  # One path that differs between two revisions.
  #
  #   status         "added", "modified", "deleted", or "renamed"
  #   previous_path  the old path of a rename, nil otherwise
  #   patch          unified diff text when requested and available (nil for
  #                  binary or oversized files)
  #   patch_status   "binary" or "oversized" when an eager patch is omitted
  #   patch_bytes    known eager patch size (not the patch itself)
  CHANGE_STATUSES = %w[added modified deleted renamed].freeze

  Change = Data.define(:path, :status, :previous_path, :patch, :additions, :deletions, :patch_status, :patch_bytes) do
    def initialize(path:, status:, previous_path: nil, patch: nil, additions: nil, deletions: nil, patch_status: nil, patch_bytes: nil)
      raise ArgumentError, "unknown change status #{status.inspect}" unless CHANGE_STATUSES.include?(status)

      super
    end
  end
end
