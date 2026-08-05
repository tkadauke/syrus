# Chat speech-to-text

Live dictation uses `ChatDictationChannel` over ActionCable. Dictation starts
before a chat message exists, so it intentionally does not reuse
`stream_chat_turn`, which is coupled to a submitted user message and
`ChatTurnJob`.

ActionCable fits the Rails, browser, and Electron deployment shape better than
HTTP upload chunks plus a separate SSE response because the browser needs one
bidirectional, authenticated connection for `start`, ordered `audio_chunk`,
`stop`, `cancel`, and transcript delta frames. Solid Cable is already the app's
cross-process cable adapter, and the same signed-in user/session boundary used
by other app channels scopes the dictation stream to one user and chat.

The stream is ephemeral. Syrus does not persist interim or final dictation text;
the frontend keeps the buffered audio blob while streaming so an `error` frame's
`fallback` payload can retry the existing backend batch endpoint.
