import { describe, expect, it } from "vitest"
import {
  PullProgressAggregator,
  formatByteSize,
  formatPullProgress,
  parsePullProgressLine
} from "../electron/installer/pullProgress"

const feed = (aggregator: PullProgressAggregator, lines: string[]) => {
  for (const line of lines) {
    const event = parsePullProgressLine(line)
    if (event) {
      aggregator.observe(event)
    }
  }
}

describe("parsePullProgressLine", () => {
  it("parses a compose layer download event", () => {
    const event = parsePullProgressLine(
      '{"id":"3f26bc2dec0b","parent_id":"Image ghcr.io/x","status":"Working","text":"Downloading","current":45200000,"total":100000000}'
    )

    expect(event).toEqual({
      id: "3f26bc2dec0b",
      text: "Downloading",
      status: "Working",
      current: 45200000,
      total: 100000000
    })
  })

  it("ignores plain-text lines from older compose (no-progress-bar degradation)", () => {
    expect(parsePullProgressLine("Pulling syrus-web ... done")).toBeNull()
    expect(parsePullProgressLine("")).toBeNull()
  })

  it("ignores malformed JSON", () => {
    expect(parsePullProgressLine('{"id":"3f26bc2dec0b","text":"Downloading"')).toBeNull()
    expect(parsePullProgressLine("{not json}")).toBeNull()
  })

  it("ignores JSON that is not a compose progress object", () => {
    expect(parsePullProgressLine('{"event":"log","line":"hello"}')).toBeNull()
    expect(parsePullProgressLine('{"id":""}')).toBeNull()
    expect(parsePullProgressLine('{"id":"abc"}')).toBeNull() // no text, no status
    expect(parsePullProgressLine('["id","abc"]')).toBeNull()
    expect(parsePullProgressLine("42")).toBeNull()
  })
})

describe("PullProgressAggregator", () => {
  it("computes a bytes-weighted percent across layers with known totals", () => {
    const aggregator = new PullProgressAggregator()
    feed(aggregator, [
      '{"id":"aaa","status":"Working","text":"Downloading","current":25000000,"total":100000000}',
      '{"id":"bbb","status":"Working","text":"Downloading","current":50000000,"total":100000000}'
    ])

    expect(aggregator.snapshot()).toEqual({
      percent: 37, // 75 MB of 200 MB, floored
      downloadedBytes: 75000000,
      totalBytes: 200000000
    })
  })

  it("counts completed layers as 100% of their total", () => {
    const aggregator = new PullProgressAggregator()
    feed(aggregator, [
      '{"id":"aaa","status":"Working","text":"Downloading","current":10000000,"total":100000000}',
      '{"id":"aaa","status":"Done","text":"Pull complete","percent":100}',
      '{"id":"bbb","status":"Working","text":"Downloading","current":0,"total":100000000}',
      '{"id":"bbb","status":"Done","text":"Download complete"}'
    ])

    expect(aggregator.snapshot()).toEqual({
      percent: 100,
      downloadedBytes: 200000000,
      totalBytes: 200000000
    })
  })

  it("falls back to completed-layers-over-known-layers when no byte totals ever appear", () => {
    const aggregator = new PullProgressAggregator()
    feed(aggregator, [
      '{"id":"aaa","status":"Done","text":"Already exists"}',
      '{"id":"bbb","status":"Done","text":"Already exists"}',
      '{"id":"ccc","status":"Working","text":"Pulling fs layer"}',
      '{"id":"ddd","status":"Working","text":"Waiting"}'
    ])

    expect(aggregator.snapshot()).toEqual({
      percent: 50, // 2 of 4 known layers done
      downloadedBytes: null,
      totalBytes: null
    })
  })

  it("caps the layer-count fallback at 99% until the image-level terminal event", () => {
    // Every layer cached: the done/known ratio is 100%, but compose may still
    // announce more layers. Only the parent "Pulled" row proves completion.
    const aggregator = new PullProgressAggregator()
    feed(aggregator, [
      '{"id":"aaa","status":"Done","text":"Already exists"}',
      '{"id":"bbb","status":"Done","text":"Already exists"}'
    ])

    expect(aggregator.snapshot().percent).toBe(99)

    feed(aggregator, ['{"id":"Image ghcr.io/tkadauke/syrus-backend:v0.1.2","status":"Done","text":"Pulled"}'])
    expect(aggregator.snapshot().percent).toBe(100)
  })

  it("accepts image-level status Done as the terminal signal too", () => {
    const aggregator = new PullProgressAggregator()
    feed(aggregator, [
      '{"id":"aaa","status":"Done","text":"Already exists"}',
      '{"id":"Image ghcr.io/tkadauke/syrus-backend:v0.1.2","status":"Done","text":""}'
    ])

    expect(aggregator.snapshot().percent).toBe(100)
  })

  it("keeps the fallback cap while any announced image is still pulling", () => {
    // A small side image finishing first must not lift the cap for the big
    // one — every announced image-level row has to reach Pulled/Done.
    const aggregator = new PullProgressAggregator()
    feed(aggregator, [
      '{"id":"Image ghcr.io/tkadauke/syrus-backend:v0.1.2","status":"Working","text":"Pulling"}',
      '{"id":"Image docker.io/library/mysql:8.0","status":"Working","text":"Pulling"}',
      '{"id":"aaa","status":"Done","text":"Already exists"}',
      '{"id":"Image docker.io/library/mysql:8.0","status":"Done","text":"Pulled"}'
    ])
    expect(aggregator.snapshot().percent).toBe(99)

    feed(aggregator, ['{"id":"Image ghcr.io/tkadauke/syrus-backend:v0.1.2","status":"Done","text":"Pulled"}'])
    expect(aggregator.snapshot().percent).toBe(100)
  })

  it("regression: early cached layers must not pin the bar while the real download runs", () => {
    // The bug: "Already exists" rows arrive first (no byte totals), the
    // layer-count fallback computes ~100%, and the old monotonic clamp then
    // froze the bar there for the entire multi-GB download.
    const aggregator = new PullProgressAggregator()
    feed(aggregator, [
      '{"id":"aaa","status":"Done","text":"Already exists"}',
      '{"id":"bbb","status":"Done","text":"Already exists"}'
    ])
    // Fallback guess, capped — never a false 100%.
    expect(aggregator.snapshot().percent).toBe(99)

    // The real multi-GB layer announces byte totals: real data replaces the
    // guess, so the percent corrects DOWNWARD once (clamp reset across the
    // fallback→bytes mode switch).
    feed(aggregator, ['{"id":"ccc","status":"Working","text":"Downloading","current":100000000,"total":2000000000}'])
    expect(aggregator.snapshot()).toEqual({
      percent: 5,
      downloadedBytes: 100000000,
      totalBytes: 2000000000
    })

    // …and stays monotonic within byte mode from there.
    feed(aggregator, ['{"id":"ccc","status":"Working","text":"Downloading","current":1000000000,"total":2000000000}'])
    expect(aggregator.snapshot().percent).toBe(50)
    feed(aggregator, ['{"id":"ccc","status":"Done","text":"Pull complete"}'])
    expect(aggregator.snapshot().percent).toBe(100)
  })

  it("resets the clamp only once, on the fallback→bytes switch, keeping byte-mode monotonicity", () => {
    const aggregator = new PullProgressAggregator()
    feed(aggregator, ['{"id":"aaa","status":"Done","text":"Already exists"}'])
    expect(aggregator.snapshot().percent).toBe(99)

    feed(aggregator, ['{"id":"bbb","status":"Working","text":"Downloading","current":90000000,"total":100000000}'])
    expect(aggregator.snapshot().percent).toBe(90)

    // A newly announced big layer grows the byte denominator: within byte
    // mode the clamp still prevents a backward jump.
    feed(aggregator, ['{"id":"ccc","status":"Working","text":"Downloading","current":0,"total":900000000}'])
    expect(aggregator.snapshot().percent).toBe(90)
  })

  it("never goes backward when newly discovered layers grow the denominator", () => {
    const aggregator = new PullProgressAggregator()
    feed(aggregator, ['{"id":"aaa","status":"Working","text":"Downloading","current":90000000,"total":100000000}'])
    expect(aggregator.snapshot().percent).toBe(90)

    // A huge new layer appears: raw percent would collapse to 9%.
    feed(aggregator, ['{"id":"bbb","status":"Working","text":"Downloading","current":0,"total":900000000}'])
    expect(aggregator.snapshot().percent).toBe(90)

    // …and resumes climbing once real progress catches up.
    feed(aggregator, ['{"id":"bbb","status":"Working","text":"Downloading","current":900000000,"total":900000000}'])
    expect(aggregator.snapshot().percent).toBe(99)
  })

  it("ignores image/container-level parent rows", () => {
    const aggregator = new PullProgressAggregator()
    feed(aggregator, [
      '{"id":"Image ghcr.io/tkadauke/syrus-backend:v0.1.2","status":"Working","text":"Pulling"}',
      '{"id":"Container syrus-web-1","status":"Working","text":"Starting"}'
    ])

    expect(aggregator.snapshot()).toEqual({ percent: null, downloadedBytes: null, totalBytes: null })
  })

  it("takes no byte counts from extraction events (different denominator)", () => {
    const aggregator = new PullProgressAggregator()
    feed(aggregator, [
      '{"id":"aaa","status":"Working","text":"Downloading","current":100000000,"total":100000000}',
      '{"id":"aaa","status":"Working","text":"Extracting","current":5000000,"total":350000000}'
    ])

    expect(aggregator.snapshot()).toEqual({
      percent: 100,
      downloadedBytes: 100000000,
      totalBytes: 100000000
    })
  })

  it("does not let a late Downloading event regress a completed layer", () => {
    const aggregator = new PullProgressAggregator()
    feed(aggregator, [
      '{"id":"aaa","status":"Working","text":"Downloading","current":40000000,"total":100000000}',
      '{"id":"aaa","status":"Done","text":"Pull complete"}',
      '{"id":"aaa","status":"Working","text":"Downloading","current":10000000,"total":100000000}'
    ])

    expect(aggregator.snapshot().downloadedBytes).toBe(100000000)
  })
})

describe("formatting", () => {
  it("formats byte sizes in decimal MB and GB like docker's CLI", () => {
    expect(formatByteSize(45200000)).toBe("45 MB")
    expect(formatByteSize(745000000)).toBe("745 MB")
    expect(formatByteSize(1500000000)).toBe("1.5 GB")
    expect(formatByteSize(0)).toBe("0 MB")
  })

  it("formats the progress label with byte counts when known", () => {
    expect(formatPullProgress({ percent: 42, downloadedBytes: 312000000, totalBytes: 745000000 })).toBe(
      "42% (312 MB / 745 MB)"
    )
  })

  it("formats a percent-only label in layer-count fallback mode", () => {
    expect(formatPullProgress({ percent: 50, downloadedBytes: null, totalBytes: null })).toBe("50%")
  })

  it("returns null while no percent is known (the UI keeps its spinner)", () => {
    expect(formatPullProgress({ percent: null, downloadedBytes: null, totalBytes: null })).toBeNull()
  })
})
