---
title: Video Walkthroughs
description: Record a narrated screen walkthrough in chat so Syrus can extract issues, desired behavior, and visual context before proposing work.
---

# Video Walkthroughs

Video walkthroughs let you start work by showing Syrus what you mean. Record a
screen with narration from a chat, or attach an existing video, and Syrus uses
Gemini to analyze the walkthrough before the chat agent proposes Jobs or an
Epic through the normal confirmation flow.

Use them when the important context is visual: a bug that needs reproduction
steps, a UI detail that is hard to describe, a QA pass across several screens,
or a "make it behave like this" request.

## How To Record

Open a Syrus chat, attach the relevant repository, then use the composer:

1. Click the `+` button.
2. Choose **Record a walkthrough**.
3. Select the screen, window, or tab you want to share.
4. Narrate what you are doing, what feels wrong, and what outcome you want.
5. Click **Stop & attach**, add an optional note in the composer, then send.

You can also click `+` and choose a video file, drag a video into the composer,
or paste a video file from the clipboard. Video walkthroughs are sent by a
separate upload path instead of the normal message-attachment path, so large
screen recordings do not become base64 chat payloads.

In the desktop app, recording can show a floating HUD and a red-pen annotation
overlay. The red pen is included when you share the full screen; on macOS,
hold-to-draw needs Accessibility permission, but recording still works without
it.

## What To Say

Narration is part of the signal. A useful walkthrough usually covers:

- What you expected to happen.
- What actually happened.
- Where the user starts and what they clicked or typed.
- Which moments are defects versus intentional behavior.
- Any screenshots, timestamps, error text, or UI areas Syrus should inspect
  closely.
- The desired end state, especially when you want a redesign rather than a
  narrow bug fix.

Short, focused videos work best. If there are several unrelated findings,
record separate walkthroughs so each proposal stays scoped.

## What Syrus Extracts

After upload, the `video_walkthroughs` plugin runs analysis on the `videos`
queue. Gemini produces a structured report with:

- A timestamped transcript.
- Sections summarizing what happened.
- Flagged issues with severity and context.
- Open questions when the video or narration is ambiguous.
- Markers for moments that need closer inspection.

The chat agent then receives an orientation prompt for the walkthrough message.
It can call walkthrough tools to read the Gemini report, inspect still frames,
and re-analyze a short segment of the video at higher detail. From there it
uses the same chat proposal machinery as typed requests: it can ask follow-up
questions, propose Jobs, or propose an Epic, and nothing becomes executable
work until you confirm it.

## Requirements

An admin must enable the bundled `video_walkthroughs` plugin. The plugin is the
feature flag: when it is disabled, the chat composer hides video intake and the
walkthrough API routes are unavailable.

Each user who records or uploads walkthroughs must configure a Gemini API key
under **Credentials**. Syrus validates the key against Gemini's `models.list`
endpoint and requires a video-capable Gemini Flash model to be available to
that key's project. The same Gemini key is also shared by Antigravity provider
setup.

The accepted video formats are:

| Format | Limit |
| --- | --- |
| `webm`, `mp4`, `mov` | Up to 15 minutes and 500 MB |

The browser checks duration before upload when it can. The backend validates
content type, size, and duration, then Gemini performs the actual video decode.

## Retention And Limits

Syrus keeps the extracted analysis and screenshots, but the stored raw video is
temporary. By default, walkthrough video blobs are retained for 7 days and are
also subject to a 2 GB instance-wide storage budget; admins can adjust
`video_retention_days` and `video_storage_budget_mb`.

Gemini's uploaded file handle is retained for about 48 hours. While that handle
is fresh, Syrus can re-analyze a segment without re-uploading the video. After
that, segment analysis falls back to the stored blob if it has not been pruned.

Only one walkthrough video can be processed per chat message, and it must be
sent on its own rather than bundled with image or PDF attachments. Analysis can
take several minutes for large recordings, and free-tier Gemini quota can delay
or fail an attempt; failed walkthroughs can be retried while the video blob is
still available.
