require "rails_helper"

# Whether a command hands work to the shell is decided by where a character
# sits, not by whether it appears anywhere in the string. Screening the raw
# text classified `grep "a*b" file` as globbing and
# `sqlite3 db "select count(*) ..."` likewise, when in both the metacharacter
# is inside quotes and the shell passes it through untouched.
#
# The two quoting forms are not equivalent and the screen must not treat them
# so: single quotes make everything literal, while a shell still expands `$`,
# a backtick and a backslash inside double quotes.
RSpec.describe CredentialStore::SshExec::RiskyCommandClassifier do
  describe ".unsafe_shell_syntax?" do
    it "ignores metacharacters the shell would never interpret" do
      expect(described_class).not_to be_unsafe_shell_syntax(%q{sqlite3 -readonly /config/db "select count(*) from states"})
      expect(described_class).not_to be_unsafe_shell_syntax(%q(grep "a*b" /var/log/syslog))
      expect(described_class).not_to be_unsafe_shell_syntax(%q(cat "/etc/os-release"))
      expect(described_class).not_to be_unsafe_shell_syntax(%q(psql -c "select a, b from t where x > 1"))
    end

    it "treats a single-quoted string as entirely literal" do
      expect(described_class).not_to be_unsafe_shell_syntax(%q(cat 'a;b'))
      expect(described_class).not_to be_unsafe_shell_syntax(%q(echo 'rm -rf / | tee $HOME'))
    end

    it "still catches what a shell expands inside double quotes" do
      expect(described_class).to be_unsafe_shell_syntax(%q{cat "$(cat ~/.ssh/id_rsa)"})
      expect(described_class).to be_unsafe_shell_syntax(%q(echo "`whoami`"))
      expect(described_class).to be_unsafe_shell_syntax(%q(echo "$HOME"))
      expect(described_class).to be_unsafe_shell_syntax('echo "a\\"b"')
    end

    it "catches unquoted shell syntax exactly as before" do
      [ "rm -rf /tmp/*", "cat /etc/passwd; rm -rf /", "ls | grep foo", "cat a > b",
        "cat $HOME/x", "echo `id`", "cat a,b", "cat ~/x", "ls [ab]" ].each do |command|
        expect(described_class).to be_unsafe_shell_syntax(command), "expected #{command.inspect} to be unsafe"
      end
    end

    it "refuses a command whose quoting never closes" do
      # What the shell would make of the rest of the line is precisely what
      # cannot be established, so it is not treated as literal text.
      expect(described_class).to be_unsafe_shell_syntax(%q(cat "unterminated))
      expect(described_class).to be_unsafe_shell_syntax(%q(cat 'unterminated))
    end
  end

  describe ".risky?" do
    it "reads an allowlisted command with a quoted metacharacter as read-only" do
      expect(described_class).not_to be_risky(%q(grep "a*b" /var/log/syslog))
      expect(described_class).not_to be_risky(%q(cat 'a;b'))
    end

    it "does not promote a command that was never allowlisted" do
      # Quoting fixes how the command is screened, not what it is allowed to
      # do: sqlite3 can still write, so it stays risky and still asks.
      expect(described_class).to be_risky(%q{sqlite3 -readonly /config/db "select count(*) from states"})
      expect(described_class).to be_risky(%q(sqlite3 /config/db "drop table states"))
    end

    it "keeps catching a command smuggled inside a quoted argument" do
      expect(described_class).to be_risky(%q(sh -c "rm -rf /"))
    end
  end
end
