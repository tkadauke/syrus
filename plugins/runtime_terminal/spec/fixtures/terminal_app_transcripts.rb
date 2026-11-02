module TerminalAppTranscripts
  PLAIN_INITIAL = "Name: ".b.freeze
  PLAIN_COMPLETE = "Ada\r\nHello, Ada!\n".b.freeze
  ALTERNATE_SCREEN = "\e[?1049h\e[2J\e[HTasks\e[2;1H> verify visual evidence\e[3;1H  ship it\e[4;1H\e[7mF1 Help\e[0m\n".b.freeze
end
