module Coworkers
  module SearchExtension
    def self.install_into(scope)
      scope.effect("coworker chat filter") do
        ::Filters.register_chips(
          subject: :chat_message,
          chips: { "coworker_id" => "Coworkers::Filters::CoworkerId" }
        )
      end
    end
  end
end
