abstract interface class LocalDriver {
  Future<String?> read(String key);
  Future<void> write(String key,String value);
  Future<void> remove(String key);
}

/// Atomic cross-tab read/compare/write, never a separate read then write.
abstract interface class AtomicLocalDriver implements LocalDriver {
  Future<bool> compareAndSwap(String key,String? expected,String? next);
}
