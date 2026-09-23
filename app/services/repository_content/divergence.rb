module RepositoryContent
  # Head relative to base as commit counts, GitHub compare's
  # ahead_by/behind_by: `ahead` is how many commits head has that base does
  # not, `behind` is how many commits base has that head does not. Both zero
  # means identical; nonzero on both sides means diverged.
  Divergence = Data.define(:ahead, :behind) do
    def initialize(ahead:, behind:)
      super(ahead: ahead.to_i, behind: behind.to_i)
    end

    def identical? = ahead.zero? && behind.zero?
    def diverged? = ahead.positive? && behind.positive?
  end
end
