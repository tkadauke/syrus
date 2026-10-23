module PendingActionGroups
  class Confirmation
    STRATEGIES = {
      "independent" => "PendingActionGroups::Confirmations::Independent",
      "dependency_sequenced" => "PendingActionGroups::Confirmations::DependencySequenced"
    }.freeze

    def self.for(group)
      keys = group.chat_pending_actions.map do |action|
        PendingActions.for(action.action.presence || action.action_type).new(action).group_confirmation_strategy
      end.uniq
      key = keys.one? ? keys.first : "independent"
      STRATEGIES.fetch(key).constantize.new(group)
    end

    def initialize(group)
      @group = group
    end

    protected

    attr_reader :group
  end
end
