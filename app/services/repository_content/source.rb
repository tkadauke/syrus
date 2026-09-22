module RepositoryContent
  # Where an upstream keeps a repository and how to fetch it: what a replica
  # (a mirror) needs to stay in sync. Only :upstream providers answer this.
  #
  #   vcs         "git", "hg", or "svn"
  #   url         the fetch URL, without credentials in it
  #   username / password
  #               HTTP basic credentials for the fetch; nil for a public URL
  #   expires_at  when the credential stops working, nil if it does not expire.
  #               Replicas must not keep using it past this.
  #
  # The credential is a secret. Never log it, persist it, or put it in a URL.
  Source = Data.define(:vcs, :url, :username, :password, :expires_at) do
    def initialize(vcs:, url:, username: nil, password: nil, expires_at: nil)
      super
    end

    # Keeps the secret out of logs, exception messages, and consoles.
    def inspect
      "#<RepositoryContent::Source vcs=#{vcs.inspect} url=#{url.inspect} credential=#{password ? '[FILTERED]' : 'none'} expires_at=#{expires_at.inspect}>"
    end
    alias_method :to_s, :inspect
  end
end
