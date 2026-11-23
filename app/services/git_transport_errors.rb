# Whether a git failure is the network between us and the remote rather than
# anything about the repository or the request. One definition, shared by the
# run failure classifier (which decides whether a failed Run is retryable) and
# the workspace clone fallback (which retries the clone itself), so the two
# never disagree about what "transient" means.
module GitTransportErrors
  module_function

  # Failures that look like a dropped connection but are really a statement
  # about the repository or the request. Retrying them only repeats the answer.
  PERMANENT_PATTERN = /authentication failed|could not read username|permission denied|access denied|repository not found|not found|couldn't find remote ref|remote ref does not exist|invalid refspec|non-fast-forward|fetch first|stale info|merge conflict|unmerged files|not a git repository|bad revision|unrelated histories/i

  # A large clone over HTTP/2 that GitHub resets mid-pack reports
  # "RPC failed; curl 92 HTTP/2 stream N was not closed cleanly", then
  # "early EOF" / "unexpected disconnect while reading sideband packet".
  TRANSIENT_PATTERN = /failed to connect|could not connect to server|connection (?:refused|reset|timed out)|network is unreachable|no route to host|could not resolve host|temporary failure in name resolution|name or service not known|unexpected disconnect|remote end hung up unexpectedly|RPC failed|early EOF|was not closed cleanly|(?:network|connect|connection|read|operation) timed? out|TLS connection was non-properly terminated|SSL_ERROR_SYSCALL|gnutls_handshake.*(?:error|failed)|HTTP (?:500|502|503|504)|The requested URL returned error: 5\d\d|\[remote rejected\].*\((?:internal server error|service unavailable|bad gateway|gateway timeout|50\d)\)/i

  def transient?(text)
    text = text.to_s
    return false if text.match?(PERMANENT_PATTERN)

    text.match?(TRANSIENT_PATTERN)
  end
end
