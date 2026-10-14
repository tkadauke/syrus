module AdminMysql
  class SqlRedactor
    STRING_LITERAL = /'(?:''|\\.|[^'\\])*(?:'|\z)|"(?:""|\\.|[^"\\])*(?:"|\z)/m
    HEX_LITERAL = /\b0x[0-9a-f]+\b/i
    NUMBER_LITERAL = /(?<![\w?])[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?(?![\w?])/i

    def self.call(value, limit:)
      return if value.blank?

      value.to_s.safe_byteslice(0, limit)
        .gsub(STRING_LITERAL, "?")
        .gsub(HEX_LITERAL, "?")
        .gsub(NUMBER_LITERAL, "?")
    end
  end
end
