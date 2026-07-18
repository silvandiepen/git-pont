/**
 * Shared URL parsing helpers used by provider modules. Mirrors the two-phase
 * parsing rules in `docs/content/architecture.md`.
 */

import type { GitProviderInstance, GitURLParseResult, GitURLReference } from "./models.js";

/** Non-empty, decoded path segments, with query and fragment stripped. */
export function pathSegments(url: string): string[] {
  const parsed = new URL(url);
  return parsed.pathname
    .split("/")
    .filter((segment) => segment.length > 0)
    .map((segment) => decodeURIComponent(segment));
}

export function hostOf(url: string): string | undefined {
  try {
    return new URL(url).host.toLowerCase();
  } catch {
    return undefined;
  }
}

export function stripGitSuffix(value: string): string {
  return value.endsWith(".git") ? value.slice(0, -4) : value;
}

/** A 7–64 char hex string is treated as a commit SHA permalink. */
export function isHexRef(value: string): boolean {
  return value.length >= 7 && value.length <= 64 && /^[0-9a-fA-F]+$/.test(value);
}

/**
 * Resolve the `<ref>/<path>` remainder of a blob/tree URL. Because branch names
 * can contain slashes, a remainder of 3+ segments is ambiguous and must be
 * disambiguated against the branch list by `GitPont.resolve`.
 */
export function parseRefPath(
  instance: GitProviderInstance,
  namespace: string,
  name: string,
  remainder: string[],
): GitURLParseResult {
  const cleanName = stripGitSuffix(name);
  const first = remainder[0];

  if (first !== undefined && isHexRef(first)) {
    return {
      kind: "resolved",
      reference: {
        instance,
        namespace,
        name: cleanName,
        ref: first,
        path: remainder.slice(1).join("/") || undefined,
      },
    };
  }

  if (remainder.length <= 2) {
    return {
      kind: "resolved",
      reference: {
        instance,
        namespace,
        name: cleanName,
        ref: first,
        path: remainder.slice(1).join("/") || undefined,
      },
    };
  }

  const candidates: GitURLReference[] = [];
  for (let split = remainder.length - 1; split >= 1; split -= 1) {
    candidates.push({
      instance,
      namespace,
      name: cleanName,
      ref: remainder.slice(0, split).join("/"),
      path: remainder.slice(split).join("/") || undefined,
    });
  }
  return { kind: "ambiguous", candidates };
}
