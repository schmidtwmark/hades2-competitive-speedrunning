// The only chat lines the server relays: the Race Board's quick lines
// (mod/src/board.lua Board.QUICK_LINES; a test keeps the two lists equal).
// There is no free text, so racers can't harass each other through the mod.
export const QUICK_LINES: readonly string[] = [
  "GG",
  "Good luck!",
  "Nice!",
  "Oops",
  "Well played",
  "Rematch?",
  "I'm using tilt controls",
  "I'm a little nervous",
];

export function isQuickLine(text: string): boolean {
  return QUICK_LINES.includes(text);
}
