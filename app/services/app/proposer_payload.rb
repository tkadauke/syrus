module App
  class ProposerPayload
    def self.for(record)
      proposer = record.proposer
      return unless proposer

      {
        type: proposer.kind,
        id: proposer.mentionable_id,
        label: proposer.try(:name).presence || proposer.try(:display_name).presence || proposer.to_s,
        handle: proposer.handle.presence
      }
    end
  end
end
