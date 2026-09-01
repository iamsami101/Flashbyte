import 'package:uuid/uuid.dart';

import 'random_words.dart';

String generateDeviceName() {
  final words = RandomWords();
  return '${_capitalize(words.firstWord)} ${_capitalize(words.secondWord)}';
}

String generateDeviceId() {
  return const Uuid().v4();
}

String _capitalize(String value) {
  if (value.isEmpty) return value;
  return '${value[0].toUpperCase()}${value.substring(1)}';
}
