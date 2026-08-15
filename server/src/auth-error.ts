export class AuthError extends Error {
  constructor(
    message: string,
    readonly status = 401,
    readonly retryAfter?: number,
    readonly code?: string,
  ) {
    super(message);
  }
}
