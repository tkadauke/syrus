# On-demand process diagnostics, triggered by SIGUSR2 and parameterised by a
# request file. See Diagnostics::SignalTrigger for why this is a signal rather
# than an endpoint, and config/syrus_docs/observability.md for operator usage.
#
# Installed in every process, web included: the handler only sets a flag until
# the signal arrives, so an unsignalled process pays nothing. Installing here
# is deliberate -- signal dispositions are inherited across fork, so each
# Solid Queue worker forked later can be addressed by its own pid without a
# supervisor hook. Solid Queue traps only INT/TERM/QUIT, leaving USR2 free.
#
# Skipped in test, where trapping would leak between examples.
Rails.application.config.after_initialize do
  Diagnostics::HeapDiagnostics.register!
  Diagnostics::ProcessDiagnostics.register!
  Diagnostics::SignalTrigger.install! unless Rails.env.test?
end
