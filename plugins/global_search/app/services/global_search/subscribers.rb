module GlobalSearch
  # Core publishes what changed; this decides what that means for the index.
  #
  # These used to be `after_commit` callbacks on Job and Epic that named index
  # job classes directly — core reaching into what is now a plugin.
  #
  # Chat message indexing deliberately stayed in core: core's own chat features
  # (in-chat search, the search_chats MCP tool, chat cleanup) read that index,
  # so it is infrastructure rather than part of this optional feature.
  class Subscribers
    include Syrus::Plugin::DomainSubscriber

    def self.subscriptions
      { "job.upserted" => :on_job_upserted, "epic.upserted" => :on_epic_upserted }
    end

    def self.on_job_upserted(event) = IndexJobSearchJob.perform_later(event[:job_id])

    def self.on_epic_upserted(event) = IndexEpicSearchJob.perform_later(event[:epic_id])
  end
end
