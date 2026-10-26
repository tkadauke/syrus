module Syrus
  module Plugin
    # Supplies mentionable entities owned by a plugin. Providers expose:
    #
    #   .mentionables(chat:) => Array<Mentionable>
    #   .find_mentionable(kind:, id:) => Mentionable or nil
    module Mentionable
      def self.included(base) = base.extend(self)
    end
  end
end
