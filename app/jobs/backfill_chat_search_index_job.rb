class BackfillChatSearchIndexJob < ApplicationJob
  BATCH_SIZE = 500
  LAST_BACKFILLED_ID_KEY = ChatMessageSearchIndex::BACKFILL_CURSOR_KEY
  SQLITE_BUSY_RETRY_ATTEMPTS = 3
  SQLITE_BUSY_RETRY_DELAY = 0.05

  queue_as :indexing

  def perform
    with_sqlite_busy_retries { ChatMessageSearchIndex.prepare_content_version! }

    loop do
      message_ids = next_batch_ids
      break if message_ids.empty?

      message_ids.each do |message_id|
        message = ChatMessage.find_by(id: message_id)
        next unless message
        next unless ChatMessageSearchIndex.indexable?(message)
        next if ChatMessageSearchIndex.indexed?(message.id)

        with_sqlite_busy_retries { ChatMessageSearchIndex.insert(message) }
      end

      with_sqlite_busy_retries { update_last_backfilled_id(message_ids.last) }
    end

    with_sqlite_busy_retries { ChatMessageSearchIndex.finish_content_version! }
  end

  private

  def next_batch_ids
    ChatMessage
      .where("chat_messages.id > ?", last_backfilled_id)
      .order(:id)
      .limit(BATCH_SIZE)
      .pluck(:id)
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

  def with_sqlite_busy_retries
    attempts = 0

    begin
      yield
    rescue ActiveRecord::StatementInvalid, ActiveRecord::StatementTimeout => e
      raise unless sqlite_busy_error?(e)

      attempts += 1
      raise if attempts > SQLITE_BUSY_RETRY_ATTEMPTS

      sleep(SQLITE_BUSY_RETRY_DELAY * attempts) unless Rails.env.test?
      retry
    end
  end

  def sqlite_busy_error?(error)
    error.message.match?(/SQLite3::BusyException|database is locked/i)
  end
end
