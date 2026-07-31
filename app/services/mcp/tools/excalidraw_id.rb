module Mcp::Tools
  module ExcalidrawId
    ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz-".chars.freeze
    LENGTH = 21

    module_function

    def generate(random: SecureRandom)
      Array.new(LENGTH) { ALPHABET[random.random_number(ALPHABET.length)] }.join
    end
  end
end
