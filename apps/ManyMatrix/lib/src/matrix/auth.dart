/// Authentication state machine for the app shell.
sealed class AuthState {
  const AuthState();
}

/// Startup: a persisted session may exist and is being restored.
class AuthRestoring extends AuthState {
  const AuthRestoring();
}

/// Logged out. [error] carries a user-facing message from a failed sign-in.
class AuthUnauthenticated extends AuthState {
  const AuthUnauthenticated([this.error]);

  final String? error;
}

/// A sign-in request is in flight.
class AuthAuthenticating extends AuthState {
  const AuthAuthenticating();
}

/// Signed in as [userId]; background sync is running.
class AuthAuthenticated extends AuthState {
  const AuthAuthenticated(this.userId);

  final String userId;
}

/// Maps raw bridge/login failures onto something a person can act on.
String friendlyLoginError(Object error) {
  final raw = error.toString();
  final lower = raw.toLowerCase();
  if (lower.contains('m_forbidden') ||
      lower.contains('invalid password') ||
      lower.contains('invalid username')) {
    return 'Incorrect username or password.';
  }
  if (lower.contains('m_user_deactivated')) {
    return 'This account has been deactivated.';
  }
  if (lower.contains('m_limit_exceeded') || lower.contains('rate limit')) {
    return 'Too many attempts. Wait a moment and try again.';
  }
  if (lower.contains('dns') ||
      lower.contains('connection refused') ||
      lower.contains('connection reset') ||
      lower.contains('timed out') ||
      lower.contains('network') ||
      lower.contains('failed to lookup') ||
      lower.contains('relative url without a base') ||
      lower.contains('invalid url')) {
    return 'Could not reach the homeserver. Check the URL and your '
        'connection.';
  }
  return 'Sign-in failed: $raw';
}
