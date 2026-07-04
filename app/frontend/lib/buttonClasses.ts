export type ButtonTone = "primary" | "secondary" | "success" | "danger" | "danger-outline"

export function buttonClass(tone: ButtonTone): string {
  const base = "inline-flex items-center rounded px-3 py-1.5 text-sm font-medium disabled:cursor-not-allowed disabled:opacity-50"
  const tones: Record<ButtonTone, string> = {
    primary: "bg-blue-600 text-white hover:bg-blue-500 dark:bg-blue-500 dark:hover:bg-blue-400",
    secondary: "border border-gray-300 bg-white text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800",
    success: "bg-emerald-600 text-white hover:bg-emerald-500 dark:bg-emerald-500 dark:hover:bg-emerald-400",
    danger: "bg-red-600 text-white hover:bg-red-500 dark:bg-red-500 dark:hover:bg-red-400",
    "danger-outline": "border border-red-300 bg-white text-red-700 hover:bg-red-50 dark:border-red-800 dark:bg-gray-900 dark:text-red-400 dark:hover:bg-red-950/30"
  }
  return `${base} ${tones[tone]}`
}
