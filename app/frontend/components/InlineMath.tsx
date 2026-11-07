import { useEffect, useState } from "react"

export function InlineMath({ expression, source }: { expression: string; source: string }) {
  const [html, setHtml] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    void import("katex").then(({ default: katex }) => {
      if (cancelled) return
      setHtml(
        katex.renderToString(expression, {
          displayMode: false,
          output: "htmlAndMathml",
          strict: false,
          throwOnError: false,
          trust: false
        })
      )
    })
    return () => {
      cancelled = true
    }
  }, [expression])

  if (!html) return source
  return <span className="syrus-inline-math" dangerouslySetInnerHTML={{ __html: html }} />
}
