module MaintenanceTasks
  class Registry
    class << self
      def definitions
        @definitions ||= [
          Definitions::AgentsBackfill.new,
          Definitions::BareCloneRemoteScrub.new,
          Definitions::ChatAttachmentBackfill.new,
          Definitions::GraderFanoutDetailsCompaction.new,
          Definitions::LandedCommitsBackfill.new,
          Definitions::PreemptedExternalPrBackfill.new,
          Definitions::SearchDatabaseRebuild.new,
          Definitions::StaleInsightBacklogRetirement.new,
          Definitions::TestInsightsGraderNameBackfill.new,
          Definitions::TestInsightsWipRepairFailureBackfill.new
        ].index_by(&:key)
      end

      def all
        definitions.values
      end

      def fetch(key)
        definitions.fetch(key.to_s)
      end

      # A stored task can name a definition this build does not have: a newer
      # pod created it before a rollback, or the definition was retired. Reads
      # that only describe the task use this, so one unknown row cannot take
      # the whole maintenance surface down.
      def find(key)
        definitions[key.to_s]
      end
    end
  end
end
