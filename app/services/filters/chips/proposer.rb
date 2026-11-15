module Filters
  module Chips
    class Proposer < Base
      filter_name "proposer"
      label "Proposer"
      bucket :enum
      operators :is, :is_not, :is_set, :is_unset

      def self.schema_values(user)
        Mentionables::Resolver.filter_candidates(user: user).filter_map do |mentionable|
          next if mentionable.handle.blank?

          { "value" => mentionable.handle, "label" => "#{mentionable.display_name} (@#{mentionable.handle})" }
        end
      end

      def apply
        case op
        when :is
          matching_scope
        when :is_not
          exclude_matches(matching_scope)
        when :is_set
          scope.where.not(proposer_type: nil).where.not(proposer_id: nil)
        when :is_unset
          scope.where(proposer_type: nil, proposer_id: nil)
        else
          unsupported_op!
        end
      end

      private

      def matching_scope
        proposer = Mentionables::Resolver.find_by_handle(value)
        return scope.none unless proposer

        scope.where(proposer_type: proposer.class.base_class.name, proposer_id: proposer.mentionable_id)
      end
    end
  end
end
