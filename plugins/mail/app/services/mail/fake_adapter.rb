module Mail
  class FakeAdapter
    class_attribute :messages, default: []

    def self.key = :fake
    def self.display_name = "Fake mail"
    def self.available_for?(context) = context.account.provider == "fake"

    def self.search(context)
      return nil unless available_for?(context)

      query = context.arguments.fetch("query", "").downcase
      { "messages" => messages.select { |message| message.to_s.downcase.include?(query) }.map { |message| message.except("body", "attachments") } }
    end

    def self.read_message(context)
      return nil unless available_for?(context)

      message = messages.find { |entry| entry.fetch("id").to_s == context.arguments.fetch("message_id").to_s }
      message ? message.deep_dup : { "message" => nil }
    end
  end
end
