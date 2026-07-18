/**
 * Normalized error model mirroring the Swift `GitPontError` enum.
 *
 * Implemented as a single `Error` subclass with a discriminated `code` and
 * optional payload, so callers can `instanceof GitPontError` and `switch` on
 * `.code`. Error messages must never contain token values.
 */

import type {
  GitConflict,
  GitProviderKind,
  GitURLReference,
  GitConnection,
  GitChangeResult,
} from "./models.js";

export type GitPontErrorCode =
  | "unsupportedURL"
  | "ambiguousURL"
  | "missingConnection"
  | "ambiguousConnection"
  | "authenticationRequired"
  | "authenticationFailed"
  | "permissionDenied"
  | "notFound"
  | "conflict"
  | "fileTooLarge"
  | "rateLimited"
  | "providerUnavailable"
  | "unsupportedCapability"
  | "invalidProviderResponse"
  | "partialSubmission";

export interface GitPontErrorData {
  conflict?: GitConflict;
  candidates?: GitURLReference[];
  providerKind?: GitProviderKind;
  instanceID?: string;
  connectionCandidates?: GitConnection[];
  retryAfter?: number;
  size?: number;
  limit?: number;
  completed?: GitChangeResult;
}

export class GitPontError extends Error {
  readonly code: GitPontErrorCode;
  readonly data: GitPontErrorData;

  constructor(code: GitPontErrorCode, message: string, data: GitPontErrorData = {}) {
    super(message);
    this.name = "GitPontError";
    this.code = code;
    this.data = data;
    // Restore prototype chain for `instanceof` across transpile targets.
    Object.setPrototypeOf(this, GitPontError.prototype);
  }

  static unsupportedURL(url: string): GitPontError {
    return new GitPontError("unsupportedURL", `Unsupported URL: ${url}`);
  }

  static ambiguousURL(candidates: GitURLReference[]): GitPontError {
    return new GitPontError("ambiguousURL", "URL is ambiguous between multiple refs", {
      candidates,
    });
  }

  static missingConnection(providerKind: GitProviderKind): GitPontError {
    return new GitPontError("missingConnection", `No connection for provider ${providerKind}`, {
      providerKind,
    });
  }

  static ambiguousConnection(instanceID: string, candidates: GitConnection[]): GitPontError {
    return new GitPontError(
      "ambiguousConnection",
      `Multiple connections exist for instance ${instanceID}`,
      { instanceID, connectionCandidates: candidates },
    );
  }

  static authenticationRequired(): GitPontError {
    return new GitPontError("authenticationRequired", "Authentication is required for this operation");
  }

  static authenticationFailed(message: string): GitPontError {
    return new GitPontError("authenticationFailed", message);
  }

  static permissionDenied(message: string): GitPontError {
    return new GitPontError("permissionDenied", message);
  }

  static notFound(message: string): GitPontError {
    return new GitPontError("notFound", message);
  }

  static conflict(conflict: GitConflict): GitPontError {
    return new GitPontError("conflict", conflict.providerMessage ?? "Remote conflict detected", {
      conflict,
    });
  }

  static fileTooLarge(size: number | undefined, limit: number): GitPontError {
    return new GitPontError("fileTooLarge", `File exceeds size limit of ${limit} bytes`, {
      size,
      limit,
    });
  }

  static rateLimited(retryAfter?: number): GitPontError {
    return new GitPontError("rateLimited", "Rate limited by provider", { retryAfter });
  }

  static providerUnavailable(message: string): GitPontError {
    return new GitPontError("providerUnavailable", message);
  }

  static unsupportedCapability(message: string): GitPontError {
    return new GitPontError("unsupportedCapability", message);
  }

  static invalidProviderResponse(message: string): GitPontError {
    return new GitPontError("invalidProviderResponse", message);
  }

  static partialSubmission(completed: GitChangeResult, failure: string): GitPontError {
    return new GitPontError("partialSubmission", failure, { completed });
  }
}

export function isGitPontError(error: unknown): error is GitPontError {
  return error instanceof GitPontError;
}
