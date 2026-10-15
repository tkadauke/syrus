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
    PHASE_KEY = "sync_phase".freeze
    PRUNE_CURSOR_KEY = "sync_prune_cursor".freeze

    Result = Data.define(:registered, :skipped, :removed, :failed)

    class Phase
      def self.for(name)
        { "inventory" => Inventory, "prune" => Prune }.fetch(name)
      end

      def initialize(sync)
        @sync = sync
      end

      class Inventory < Phase
        def run = @sync.run_inventory
      end

      class Prune < Phase
        def run = @sync.run_prune
      end
    end

    def self.run!(client: nil)
      endpoint = ContentProvider.endpoint
      return nil unless endpoint

      new(client: client || Client.new(endpoint: endpoint)).run!
    end

    def initialize(client:)
      @client = client
    end

    def run!
      Phase.for(phase_name).new(self).run
    end

    def run_inventory
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

      if complete
        write_state(from_phase: "inventory", from_cursor: starting_cursor, phase: "prune", cursor: nil)
      else
        write_state(from_phase: "inventory", from_cursor: starting_cursor, phase: "inventory", cursor: batch.last.id)
      end

      Result.new(registered:, skipped:, removed: [], failed:)
    end

    def run_prune
      starting_cursor = prune_cursor
      page = @client.list_page(cursor: starting_cursor.presence, limit: BATCH_SIZE)
      mirrored_ids = page.fetch("repositories").map { |entry| entry.fetch("id") }
      active_ids = Repository.active.git.where(id: mirrored_ids).pluck(:id).map(&:to_s)
      removed = (mirrored_ids - active_ids).filter_map do |id|
        @client.remove(id)
        id
      rescue StandardError => e
        Rails.logger.warn("[GitMirror] could not remove #{id}: #{e.class}: #{e.message}")
        nil
      end

      if page.fetch("has_more")
        write_state(from_phase: "prune", from_cursor: starting_cursor, phase: "prune", cursor: page.fetch("next_cursor"))
      else
        write_state(from_phase: "prune", from_cursor: starting_cursor, phase: "inventory", cursor: nil)
      end
      Result.new(registered: [], skipped: [], removed:, failed: [])
    rescue StandardError => e
      Rails.logger.warn("[GitMirror] could not prune the mirror: #{e.class}: #{e.message}")
      Result.new(registered: [], skipped: [], removed: [], failed: [])
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

    def prune_cursor
      plugin_record.config.to_h[PRUNE_CURSOR_KEY].to_s
    end

    def phase_name
      plugin_record.config.to_h.fetch(PHASE_KEY, "inventory")
    end

    # Concurrent ticks may repeat a page, but must never move the durable
    # cursor backwards after another tick has already advanced it.
    def write_state(from_phase:, from_cursor:, phase:, cursor:)
      plugin_record.with_lock do
        config = plugin_record.config.to_h
        current_phase = config.fetch(PHASE_KEY, "inventory")
        cursor_key = current_phase == "prune" ? PRUNE_CURSOR_KEY : CURSOR_KEY
        current_cursor = current_phase == "prune" ? config[cursor_key].to_s : config[cursor_key].to_i
        return unless current_phase == from_phase && current_cursor == from_cursor

        config[PHASE_KEY] = phase
        config.delete(CURSOR_KEY)
        config.delete(PRUNE_CURSOR_KEY)
        target_key = phase == "prune" ? PRUNE_CURSOR_KEY : CURSOR_KEY
        config[target_key] = cursor if cursor.present?
        plugin_record.update!(config: config)
      end
    end

    def plugin_record
      @plugin_record ||= PluginRecord.find_or_create_by!(name: "git_mirror")
    end

  end
end
