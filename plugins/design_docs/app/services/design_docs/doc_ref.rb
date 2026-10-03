module DesignDocs
  module DocRef
    module_function

    def parse(value)
      token = value.to_s.strip
      match = token.match(/\ADOC-(\d+)\z/i)
      return match[1].to_i if match

      Integer(token, exception: false)
    end
  end
end
