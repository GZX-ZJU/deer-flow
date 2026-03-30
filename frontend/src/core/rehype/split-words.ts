const CODE_LIKE_PATTERNS = [
  /https?:\/\//i,
  /\/[\w.-]+\/[\w./-]*/,
  /[A-Za-z0-9_.-]+\.[A-Za-z0-9]+/,
  /--?[A-Za-z][\w-]*/,
  /[A-Za-z]:\\/,
  /[`$#{}()[\];<>]/,
];

function containsAsciiWord(text: string): boolean {
  return /[A-Za-z0-9]/.test(text);
}

function containsHan(text: string): boolean {
  return /\p{Script=Han}/u.test(text);
}

export function shouldAnimateTextNode(text: string): boolean {
  const normalized = text.trim();
  if (!normalized) {
    return false;
  }

  if (CODE_LIKE_PATTERNS.some((pattern) => pattern.test(normalized))) {
    return false;
  }

  if (containsAsciiWord(normalized)) {
    return false;
  }

  return containsHan(normalized);
}

export function splitTextForAnimation(text: string): string[] {
  if (!shouldAnimateTextNode(text)) {
    return [text];
  }

  const segmenter = new Intl.Segmenter("zh", { granularity: "word" });
  return Array.from(segmenter.segment(text))
    .map((segment) => segment.segment)
    .filter(Boolean);
}
