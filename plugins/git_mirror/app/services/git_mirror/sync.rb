module GitMirror
  # Tells the mirror what to mirror, once a minute: every active git
  # repository, with where to fetch it and a fresh credential, and removes
  # the ones Syrus no longer works on.
  #
  # Pushing the credential every tick is what keeps the mirror free of
  # long-lived secrets: it holds a short-lived token in memory, and if Syrus
  # stops sending one it simply stops fetching.
  class Sync
    Result = Data.define(:registered, :skipped, :removed, :failed)

    def self.run!(client: nil)
      endpoint = ContentProvider.endpoint
      return nil unless endpoint

      new(client: client || Client.new(endpoint: endpoint)).run!
    end

    def initialize(client:)
      @client = client
    end

    def run!
      registered = []
      skipped = []
      failed = []
      repositories.each do |repository|
        source = RepositoryContent.upstream_source_for(repository)
        next skipped << repository.id unless source

        @client.register(repository.id.to_s, source)
        registered << repository.id
      rescue StandardError => e
        failed << repository.id
        Rails.logger.warn("[GitMirror] could not register #{repository.slug}: #{e.class}: #{e.message}")
      end

      Result.new(registered: registered, skipped: skipped, removed: remove_stale(registered + skipped + failed), failed: failed)
    end

    private

    def repositories
      Repository.active.select { |repository| repository.vcs == "git" }
    end

    # Only after a successful listing, and never a repository that is still
    # active: a failed registration is a reason to try again next tick, not
    # to throw away the mirror.
    def remove_stale(active_ids)
      keep = active_ids.map(&:to_s)
      @client.list.map { |entry| entry.fetch("id") }.reject { |id| keep.include?(id) }.each do |id|
        @client.remove(id)
      end
    rescue StandardError => e
      Rails.logger.warn("[GitMirror] could not prune the mirror: #{e.class}: #{e.message}")
      []
    end
  end
end
