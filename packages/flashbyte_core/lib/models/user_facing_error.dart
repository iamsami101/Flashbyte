class UserFacingError {
  const UserFacingError({required this.message, this.details});

  final String message;
  final String? details;

  bool get hasDetails => details != null && details!.trim().isNotEmpty;

  static UserFacingError from(Object? error) {
    final raw = (error ?? 'Unknown error').toString().trim();
    final lower = raw.toLowerCase();
    final (summary, details) = _splitDetails(raw);

    final knownMessage = _knownMessage(lower);
    if (knownMessage != null) {
      return UserFacingError(message: knownMessage);
    }

    return UserFacingError(
      message: summary.isEmpty ? 'Something went wrong.' : summary,
      details: details ?? raw,
    );
  }

  static String? _knownMessage(String lower) {
    if (_containsAny(lower, [
      'socket startup was cancelled',
      'connection setup was cancelled',
    ])) {
      return 'Connection setup was interrupted. Try again.';
    }

    if (_containsAny(lower, [
      'other device disconnected during the transfer',
      'disconnected unexpectedly',
      'connection reset by peer',
      'broken pipe',
      'write failed',
      'software caused connection abort',
    ])) {
      return 'The other device disconnected before the transfer finished.';
    }

    if (_containsAny(lower, [
      'no route to host',
      'connection refused',
      'connection timed out',
      'network is unreachable',
      'host is unreachable',
      'failed host lookup',
      'errno = 111',
      'errno=111',
      'errno = 113',
      'errno=113',
      'errno = 101',
      'errno=101',
      'socketexception',
      'could not reach',
    ])) {
      return 'Could not reach the receiver. Check the IP address, port, Wi-Fi, and that the receiver is ready.';
    }

    if (_containsAny(lower, [
      'invalid address',
      'invalid ip',
      'address is invalid',
      'illegal ipv',
      'format exception',
    ])) {
      return 'That IP address does not look valid.';
    }

    if (_containsAny(lower, [
      'tls enabled',
      'tls disabled',
      'incompatible certificate',
      'certificate unknown',
      'invalid peer certificate',
      'handshake',
      'caused as end entity',
      'ca used as end entity',
    ])) {
      return 'The TLS settings do not match. Make sure TLS is enabled or disabled on both devices, then try again.';
    }

    if (_containsAny(lower, [
      'certificate files not found',
      'failed to load certificate',
    ])) {
      return 'The TLS certificate could not be loaded. Check the TLS certificate settings and try again.';
    }

    if (_containsAny(lower, [
      'socket not connected',
      'connection is not active',
    ])) {
      return 'The connection is not active anymore. Reconnect and try again.';
    }

    if (_containsAny(lower, [
      'could not read selected file metadata',
      'file may have been moved or deleted',
      'file not found',
    ])) {
      return 'The selected file could not be read. It may have been moved or deleted.';
    }

    if (_containsAny(lower, [
      'could not save the received file',
      'could not save the destination file',
      'android saf response',
    ])) {
      return 'The received file could not be saved. Choose a different folder and try again.';
    }

    if (_containsAny(lower, [
      'permission denied',
      'operation not permitted',
      'access is denied',
    ])) {
      return 'Permission was denied. Check file or folder permissions and try again.';
    }

    return null;
  }

  static (String, String?) _splitDetails(String message) {
    final detailsSeparator = RegExp(r'\n\nDetails:\s*');
    final detailsMatch = detailsSeparator.firstMatch(message);
    if (detailsMatch == null) {
      return (message, null);
    }
    return (
      message.substring(0, detailsMatch.start).trim(),
      message.substring(detailsMatch.end).trim(),
    );
  }

  static bool _containsAny(String value, List<String> needles) {
    return needles.any(value.contains);
  }
}
