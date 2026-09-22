module RepositoryContent
  # An immutable point in a repository's history. `id` is the VCS's own token
  # (git SHA, hg changeset hash, svn `branch@rev`) and is what every other
  # read is keyed by. `ref` is the name it was resolved from, if any, and
  # `observed_at` when that resolution happened.
  Revision = Data.define(:id, :ref, :observed_at) do
    def initialize(id:, ref: nil, observed_at: nil)
      raise ArgumentError, "revision id is required" if id.blank?

      super(id: id.to_s, ref: ref, observed_at: observed_at)
    end

    def to_s = id
  end
end
