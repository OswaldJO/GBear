/// Signals [GBearHostClient.requestPair] to stop polling and withdraw the Mac request.
class PairingCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}
