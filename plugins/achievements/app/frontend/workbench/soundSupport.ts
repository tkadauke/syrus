// Reveals play no sound today, so there is nothing for the workbench to
// audition. When production gains sound, export the real player here and the
// workbench's opt-in audio toggle (and its discussion payload) light up
// without any other change.
export type AchievementSoundSupport = { play: (rarity: string) => void }

export const achievementSoundSupport: AchievementSoundSupport | null = null
