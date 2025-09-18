import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:async';

class PurchaseService {
  final _storage = const FlutterSecureStorage();
  
  static const String _trialStartKey = 'trial_start';
  static const String _lifetimeKey = 'lifetime_purchase';
  static const String _subExpiryKey = 'subscription_expiry';

  Future<void> startTrial() async {
    final startDate = DateTime.now().toIso8601String();
    await _storage.write(key: _trialStartKey, value: startDate);
  }

  Future<bool> isTrialActive() async {
    final startStr = await _storage.read(key: _trialStartKey);
    if (startStr == null) return false;
    final startDate = DateTime.parse(startStr);
    return DateTime.now().isBefore(startDate.add(const Duration(days: 14)));
  }

  Future<bool> hasLifetime() async {
    return (await _storage.read(key: _lifetimeKey)) == "true";
  }

  Future<DateTime?> subscriptionExpiry() async {
    final expiry = await _storage.read(key: _subExpiryKey);
    return expiry != null ? DateTime.tryParse(expiry) : null;
  }

  Future<bool> hasValidSubscription() async {
    final expiry = await subscriptionExpiry();
    return expiry != null && DateTime.now().isBefore(expiry);
  }

  Future<bool> isEntitled() async {
    return await hasLifetime() || await hasValidSubscription() || await isTrialActive();
  }

  Future<void> setLifetime(bool value) async {
  await _storage.write(key: _lifetimeKey, value: value ? "true" : "false");
}

  Future<void> extendSubscription({required int days}) async {
    final now = DateTime.now();
    final expiryStr = await _storage.read(key: _subExpiryKey);
    DateTime expiry = expiryStr != null ? DateTime.parse(expiryStr) : now;
    if (expiry.isBefore(now)) expiry = now;
    expiry = expiry.add(Duration(days: days));
    await _storage.write(key: _subExpiryKey, value: expiry.toIso8601String());
  }

  // Returns remaining trial days (0 if expired or never started)
  Future<int> remainingTrialDays() async {
    final startStr = await _storage.read(key: _trialStartKey);
    if (startStr == null) return 0;
    final startDate = DateTime.parse(startStr);
    final diff = DateTime.now().difference(startDate).inDays;
    return (14 - diff).clamp(0, 14); // min 0, max 14
  }

}
