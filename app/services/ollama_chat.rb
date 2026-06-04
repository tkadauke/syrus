require "net/http"
require "json"
require "uri"

# Streams a chat completion from a locally-running Ollama instance using
# the OpenAI-compatible /v1/chat/completions endpoint. Yields each text
# delta to the provided block as it arrives, then returns the full text.
class OllamaChat
  DEFAULT_SYSTEM_PROMPT = "You are a helpful software engineering assistant."

  def initialize(model:, base_url: nil)
    @model = model.presence || OpencodeInvocation::DEFAULT_OLLAMA_MODEL
    @base_url = (base_url || ENV.fetch("SYRUS_OLLAMA_URL", OpencodeInvocation::DEFAULT_OLLAMA_URL)).chomp("/")
  end

  # messages: array of {role:, content:} hashes (OpenAI format)
  # Yields each text chunk as it streams, returns full response text.
  def complete(messages, &chunk_handler)
    uri = URI("#{@base_url}/v1/chat/completions")
    body = {
      model: @model,
      messages: messages,
      stream: true
    }

    full_text = +""
    http_stream(uri, body) do |delta|
      full_text << delta
      chunk_handler&.call(delta)
    end
    full_text
  end

  private

  def http_stream(uri, body)
    Net::HTTP.start(uri.host, uri.port, read_timeout: 300, open_timeout: 10) do |http|
      request = Net::HTTP::Post.new(uri.path)
      request["Content-Type"] = "application/json"
      request.body = body.to_json

      http.request(request) do |response|
        unless response.code == "200"
          raise "Ollama returned #{response.code}: #{response.body&.slice(0, 200)}"
        end

        response.read_body do |chunk|
          chunk.split("\n").each do |line|
            next unless line.start_with?("data: ")

            data = line.delete_prefix("data: ").strip
            next if data == "[DONE]"

            event = JSON.parse(data)
            delta = event.dig("choices", 0, "delta", "content").to_s
            yield delta if delta.present?
          rescue JSON::ParserError
            next
          end
        end
      end
    end
  end
end
