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
            tokens << (bareword_fts_token?(token) ? token : quote_fts_phrase(token))
          end
          index = next_quote_index
        end
      end

      tokens.join(" ")
    end

    # FTS5's enhanced query syntax gives special meaning to punctuation like
    # `:` (column filter), `=`/`<`/`>` (comparisons in some builds), `/`,
    # `(`, `)`, `*`, and `-` (exclusion) outside of a quoted phrase. Real log
    # messages are full of tokens like "SolidCable::TrimJob", "job_id=42", or
    # "/api/v1/app/...", which raised SQLite3::SQLException on a raw MATCH.
    # Quoting anything but plain alphanumeric/underscore words sidesteps the
    # query-syntax parser entirely and searches the token as a literal phrase.
    def bareword_fts_token?(token)
      token.match?(/\A[[:alnum:]_]+\z/)
    end

    def quote_fts_phrase(value)
      %("#{value.to_s.gsub('"', '""')}")
    end
  end
end
