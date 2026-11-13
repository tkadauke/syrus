module Admin
  module Transcripts
    class RawStream
      CHUNK_BYTES = 64.kilobytes

      def initialize(provider_session_id)
        @provider_session_id = provider_session_id
      end

      def bytesize
        select_value("LENGTH(HEX(transcript_jsonl))").to_i / 2
      end

      def each
        return enum_for(:each) unless block_given?

        offset = 1
        loop do
          hex_chunk = select_value("SUBSTRING(HEX(transcript_jsonl), #{(offset - 1) * 2 + 1}, #{CHUNK_BYTES * 2})")
          break if hex_chunk.blank?

          chunk = [ hex_chunk ].pack("H*").force_encoding(Encoding::UTF_8)
          yield chunk
          offset += chunk.bytesize
        end
      end

      private

      def select_value(expression)
        connection = ProviderSession.connection
        id = connection.quote(@provider_session_id)
        connection.select_value("SELECT #{expression} FROM provider_sessions WHERE id = #{id}")
      end
    end
  end
end
