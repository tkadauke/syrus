module CiRepair
  class CheckEnricher
    def self.call(check)
      new(check).call
    end

    def initialize(check)
      @check = check.to_h
    end

    def call
      name = value(:name)
      summary = value(:summary)
      log = delete_value(:log)
      full_log_url = value(:html_url) || value(:details_url) || value(:url)
      parser_input = log.presence || summary.to_s

      @check.merge(
        error_context: CiLogParser.new(
          parser_input,
          step_name: name,
          full_log_url: full_log_url
        ).parse
      )
    end

    private

    def value(key)
      @check[key] || @check[key.to_s]
    end

    def delete_value(key)
      @check.delete(key) || @check.delete(key.to_s)
    end
  end
end
