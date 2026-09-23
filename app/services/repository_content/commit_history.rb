module RepositoryContent
  # The commits `head` introduced since its merge base with `base` (three-dot,
  # like Change), newest-first, plus that merge base's revision id.
  CommitHistory = Data.define(:commits, :merge_base_id) do
    def initialize(commits: [], merge_base_id: nil)
      super(commits: commits, merge_base_id: merge_base_id)
    end
  end
end
