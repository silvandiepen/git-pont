import { describe, expect, it } from "vitest";
import { GitHubProvider, GitPontError } from "../src/index.js";
import { MockHttpClient } from "./helpers.js";

const provider = new GitHubProvider(new MockHttpClient(() => {
  throw new Error("no network in URL tests");
}));

describe("GitHub URL parsing", () => {
  it("parses a bare repository URL", () => {
    const result = provider.parse("https://github.com/silvandiepen/git-pont");
    expect(result.kind).toBe("resolved");
    if (result.kind !== "resolved") return;
    expect(result.reference.namespace).toBe("silvandiepen");
    expect(result.reference.name).toBe("git-pont");
    expect(result.reference.ref).toBeUndefined();
  });

  it("strips a .git suffix", () => {
    const result = provider.parse("https://github.com/o/r.git");
    expect(result.kind === "resolved" && result.reference.name).toBe("r");
  });

  it("parses a blob URL with a simple ref and path", () => {
    const result = provider.parse("https://github.com/o/r/blob/main/README.md");
    expect(result.kind).toBe("resolved");
    if (result.kind !== "resolved") return;
    expect(result.reference.ref).toBe("main");
    expect(result.reference.path).toBe("README.md");
  });

  it("returns ambiguous candidates for slash-containing branch names", () => {
    const result = provider.parse("https://github.com/o/r/blob/feature/foo/doc.md");
    expect(result.kind).toBe("ambiguous");
    if (result.kind !== "ambiguous") return;
    // Longest ref candidate first.
    expect(result.candidates[0]?.ref).toBe("feature/foo");
    expect(result.candidates[0]?.path).toBe("doc.md");
    expect(result.candidates[1]?.ref).toBe("feature");
    expect(result.candidates[1]?.path).toBe("foo/doc.md");
  });

  it("treats a commit SHA permalink as resolved", () => {
    const sha = "a".repeat(40);
    const result = provider.parse(`https://github.com/o/r/blob/${sha}/a/b/c.md`);
    expect(result.kind).toBe("resolved");
    if (result.kind !== "resolved") return;
    expect(result.reference.ref).toBe(sha);
    expect(result.reference.path).toBe("a/b/c.md");
  });

  it("parses raw.githubusercontent.com URLs", () => {
    const result = provider.parse("https://raw.githubusercontent.com/o/r/main/file.md");
    expect(result.kind).toBe("resolved");
    if (result.kind !== "resolved") return;
    expect(result.reference.ref).toBe("main");
    expect(result.reference.path).toBe("file.md");
  });

  it("treats a raw URL with a deep path as ambiguous (slash-branch)", () => {
    const result = provider.parse("https://raw.githubusercontent.com/o/r/main/dir/file.md");
    expect(result.kind).toBe("ambiguous");
  });

  it("throws for unsupported hosts", () => {
    expect(() => provider.parse("https://example.com/o/r")).toThrow(GitPontError);
  });
});
