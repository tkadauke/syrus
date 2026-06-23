class BackfillChatSearchIndexJob < ApplicationJob
  BATCH_SIZE = 500
  LAST_BACKFILLED_ID_KEY = "last_backfilled_id".freeze

  queue_as :default

  def perform
    loop do
      messages = next_batch
      break if messages.empty?

      messages.each do |message|
        next unless ChatMessageSearchIndex.indexable?(message)
        next if ChatMessageSearchIndex.indexed?(message.id)

        ChatMessageSearchIndex.insert(message)
      end

      update_last_backfilled_id(messages.last.id)
    end
  end

  private

  def next_batch
    ChatMessage
      .includes(:chat_session)
      .where("id > ?", last_backfilled_id)
      .order(:id)
      .limit(BATCH_SIZE)
      .to_a
  end

  def last_backfilled_id
    ChatMessageSearchIndex.connection.select_value(
      "SELECT value FROM chat_search_metadata WHERE key = ?",
      "BackfillChatSearchIndexJob Last Backfilled",
      [ bind(LAST_BACKFILLED_ID_KEY) ]
    ).to_i
  end

  def update_last_backfilled_id(message_id)
    ChatMessageSearchIndex.connection.exec_insert(
      "INSERT OR REPLACE INTO chat_search_metadata (key, value) VALUES (?, ?)",
      "BackfillChatSearchIndexJob Update Progress",
      [
        bind(LAST_BACKFILLED_ID_KEY),
        bind(message_id.to_s)
      ]
    )
  end

  def bind(value)
    ActiveRecord::Relation::QueryAttribute.new(nil, value, ActiveRecord::Type::Value.new)
  end
end
