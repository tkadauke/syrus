module RepositoryContent
  # One commit in a revision's history.
  Commit = Data.define(:sha, :message, :authored_at) do
    def initialize(sha:, message: "", authored_at: nil)
      raise ArgumentError, "commit sha is required" if sha.blank?

      super(sha: sha.to_s, message: message.to_s, authored_at: authored_at)
    end
  end
end
