module PushProtection
  # Harness-controlled commit metadata, taken from the rejected tip, so the
  # reconstructed commit is byte-identical however the agent produced its tree.
  Metadata = Data.define(:author_name, :author_email, :author_date,
                         :committer_name, :committer_email, :committer_date, :message) do
    SEP = "\u001f".freeze

    def self.capture(repo, rev)
      fields = repo.out("log", "-1", "--format=%an#{SEP}%ae#{SEP}%aI#{SEP}%cn#{SEP}%ce#{SEP}%cI", rev).split(SEP, -1)
      message = repo.run("log", "-1", "--format=%B", rev).strip
      new(*fields, message)
    end

    def self.from_h(hash) = new(*members.map { |m| hash.fetch(m.to_s) })

    def env
      {
        "GIT_AUTHOR_NAME" => author_name, "GIT_AUTHOR_EMAIL" => author_email, "GIT_AUTHOR_DATE" => author_date,
        "GIT_COMMITTER_NAME" => committer_name, "GIT_COMMITTER_EMAIL" => committer_email,
        "GIT_COMMITTER_DATE" => committer_date
      }
    end
  end
end
