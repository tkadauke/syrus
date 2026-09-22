module RepositoryContent
  Ref = Data.define(:name, :revision_id, :observed_at) do
    def initialize(name:, revision_id:, observed_at: nil)
      raise ArgumentError, "ref name is required" if name.blank?
      raise ArgumentError, "revision id is required" if revision_id.blank?

      super(name: name.to_s, revision_id: revision_id.to_s, observed_at: observed_at)
    end
  end
end
