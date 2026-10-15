module GitMirror
  # Tells the mirror what to mirror, once a minute: every active git
  # repository, with where to fetch it and a fresh credential, and removes
  # the ones Syrus no longer works on.
  #
  # Pushing the credential every tick is what keeps the mirror free of
  # long-lived secrets: it holds a short-lived token in memory, and if Syrus
  # stops sending one it simply stops fetching.
  class Sync
    BATCH_SIZE = 100
    CURSOR_KEY = "sync_repository_cursor".freeze

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
      batch, complete, starting_cursor = next_batch
      batch.each do |repository|
        source = RepositoryContent.upstream_source_for(repository)
        next skipped << repository.id unless source

        @client.register(repository.id.to_s, source)
        registered << repository.id
      rescue StandardError => e
        failed << repository.id
        Rails.logger.warn("[GitMirror] could not register #{repository.slug}: #{e.class}: #{e.message}")
      end

      removed = complete ? remove_stale : []
      write_cursor(complete ? nil : batch.last.id, from: starting_cursor)

      Result.new(registered:, skipped:, removed:, failed:)
    end

    private

    def next_batch
      starting_cursor = cursor
      repositories = Repository.active.git.where("id > ?", starting_cursor).order(:id).limit(BATCH_SIZE + 1).to_a
      complete = repositories.length <= BATCH_SIZE
      [ repositories.first(BATCH_SIZE), complete, starting_cursor ]
    end

    def cursor
      plugin_record.config.to_h[CURSOR_KEY].to_i
    end

    # Concurrent ticks may repeat a page, but must never move the durable
    # cursor backwards after another tick has already advanced it.
    def write_cursor(value, from:)
      plugin_record.with_lock do
        config = plugin_record.config.to_h
        return unless config[CURSOR_KEY].to_i == from

        value ? config[CURSOR_KEY] = value : config.delete(CURSOR_KEY)
        plugin_record.update!(config: config)
      end
    end

    def plugin_record
      @plugin_record ||= PluginRecord.find_or_create_by!(name: "git_mirror")
    end

    # Only after a successful listing, and never a repository that is still
    # active: a failed registration is a reason to try again next tick, not
    # to throw away the mirror.
    def remove_stale
      mirrored_ids = @client.list.map { |entry| entry.fetch("id") }
      active_ids = Repository.active.git.where(id: mirrored_ids).pluck(:id).map(&:to_s)
      (mirrored_ids - active_ids).each do |id|
        @client.remove(id)
      end
    rescue StandardError => e
      Rails.logger.warn("[GitMirror] could not prune the mirror: #{e.class}: #{e.message}")
      []
    end
  end
end
