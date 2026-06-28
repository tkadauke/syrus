module FtsQueryParser
  extend ActiveSupport::Concern

  class_methods do
    private

    def parse_fts_query(raw)
      query = raw.to_s
      tokens = []
      index = 0

      while index < query.length
        if query[index] == '"'
          closing_index = query.index('"', index + 1)
          phrase = if closing_index
            query[(index + 1)...closing_index]
          else
            query[(index + 1)..]
          end

          tokens << quote_fts_phrase(phrase) if phrase.present?
          index = closing_index ? closing_index + 1 : query.length
        else
          next_quote_index = query.index('"', index) || query.length
          query[index...next_quote_index].to_s.split.each do |token|
            tokens << (token.include?("-") ? quote_fts_phrase(token) : token)
          end
          index = next_quote_index
        end
      end

      tokens.join(" ")
    end

    def quote_fts_phrase(value)
      %("#{value.to_s.gsub('"', '""')}")
    end
  end
end
