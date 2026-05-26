require "net/http"
require "uri"

module ChatChannel
  class Telegram
    THREAD_PREFIX = "telegram".freeze
    API_HOST = "api.telegram.org".freeze

    attr_reader :http, :token

    def self.bot_token
      ENV["TELEGRAM_BOT_TOKEN"].presence || AppSetting.current.telegram_bot_token.presence
    end

    def self.webhook_secret
      ENV["TELEGRAM_WEBHOOK_SECRET"].presence || AppSetting.current.telegram_webhook_secret.presence
    end

    def initialize(http: Net::HTTP, token: self.class.bot_token)
      @http = http
      @token = token.to_s.presence
    end

    def send_message(run:, text:, context: {}, asked_at: Time.current)
      workflow = run.workflow || run.job.latest_workflow
      raise ArgumentError, "run must belong to a Workflow" unless workflow

      question = OperatorQuestion.create!(
        run: run,
        workflow: workflow,
        job: run.job,
        text: text,
        context: (context.presence || {}).merge("channel" => "telegram"),
        asked_at: asked_at
      )

      deliver_question(question)
    end

    def deliver_question(question)
      run = question.run
      chat_id = run.job.user.telegram_chat_id.to_s.presence
      raise ConfigurationError, "Telegram chat id is not configured for #{run.job.user.email_address}" if chat_id.blank?
      raise ConfigurationError, "Telegram bot token is not configured" if token.blank?

      payload = {
        chat_id: chat_id,
        text: question.text,
        disable_web_page_preview: true
      }
      if (reply_message_id = previous_message_id_for(run, chat_id))
        payload[:reply_parameters] = { message_id: reply_message_id }
      end

      response = post_json("sendMessage", payload)
      message_id = response.dig("result", "message_id")
      raise DeliveryError, "Telegram sendMessage response did not include result.message_id" if message_id.blank?

      thread_id = self.class.thread_id(chat_id: chat_id, message_id: message_id)
      run.update!(operator_chat_thread_id: thread_id)
      question.update!(context: question.context.merge("thread_id" => thread_id))

      question
    end

    def receive_update!(payload)
      message = payload["message"] || payload["edited_message"]
      return false unless message

      text = message["text"].to_s.strip
      chat_id = message.dig("chat", "id").to_s
      reply_to_message_id = message.dig("reply_to_message", "message_id")
      return false if text.blank? || chat_id.blank? || reply_to_message_id.blank?

      thread_id = self.class.thread_id(chat_id: chat_id, message_id: reply_to_message_id)
      run = Run.where(operator_chat_thread_id: thread_id).order(:created_at).last
      return false unless run

      OperatorQuestion.transaction do
        run.update!(operator_chat_response: text)
        run.operator_questions.order(:asked_at, :created_at).last&.record_response!(text: text)
      end
      run.continue_after_operator_response!(response_text: text)
    end

    def self.thread_id(chat_id:, message_id:)
      "#{THREAD_PREFIX}:#{chat_id}:#{message_id}"
    end

    def self.parse_thread_id(thread_id)
      prefix, chat_id, message_id = thread_id.to_s.split(":", 3)
      return nil unless prefix == THREAD_PREFIX && chat_id.present? && message_id.present?

      { chat_id: chat_id, message_id: Integer(message_id, exception: false) }
    end

    private

    def previous_message_id_for(run, chat_id)
      prior_thread = run.job.runs
                        .where.not(id: run.id)
                        .where.not(operator_chat_thread_id: [ nil, "" ])
                        .order(:created_at)
                        .last
                        &.operator_chat_thread_id
      parsed = self.class.parse_thread_id(prior_thread)
      return nil unless parsed && parsed[:chat_id] == chat_id

      parsed[:message_id]
    end

    def post_json(method_name, payload)
      uri = URI::HTTPS.build(host: API_HOST, path: "/bot#{token}/#{method_name}")
      request = Net::HTTP::Post.new(uri)
      request.content_type = "application/json"
      request.body = JSON.generate(payload)

      response = http.start(uri.host, uri.port, use_ssl: true) { |connection| connection.request(request) }
      body = JSON.parse(response.body.to_s)
      return body if response.is_a?(Net::HTTPSuccess) && body["ok"]

      description = body["description"].presence || response.message
      raise DeliveryError, "Telegram #{method_name} failed: #{description}"
    rescue JSON::ParserError
      raise DeliveryError, "Telegram #{method_name} returned invalid JSON"
    end
  end
end
