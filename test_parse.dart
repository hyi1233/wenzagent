import 'dart:convert';
import 'dart:io';

void main() async {
  final lines = await File('test_output.json').readAsLines();
  Map<int, String> testNames = {};
  int pass = 0, fail = 0;
  for (final line in lines) {
    try {
      final map = jsonDecode(line);
      if (map is Map) {
        if (map['type'] == 'testStart') {
          testNames[map['testID'] as int] = map['name'] as String? ?? '';
        }
        if (map['type'] == 'error') {
          final testName = testNames[map['testID'] as int? ?? -1] ?? 'unknown';
          print('=== ERROR Test ${map['testID']}: $testName ===');
          print('Error: ${map['error']}');
          print('Stack: ${map['stackTrace']}');
          print('');
        }
        if (map['type'] == 'testDone') {
          if (map['result'] == 'success') pass++;
          else if (map['result'] == 'failure') fail++;
        }
      }
    } catch (_) {}
  }
  print('Pass: $pass, Fail: $fail, Total: ${pass + fail}');
}
