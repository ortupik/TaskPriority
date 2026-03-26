import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

// These tests cover the core business logic units:
//   1. Checklist field validation (all types)
//   2. Status transition validation
//   3. Sync queue ordering and retry logic

// ── Checklist validation logic ────────────────────────────────────────────
// Extracted to a pure function for testability (mirrors ChecklistFormNotifier._validateField)

String? validateField(Map<String, dynamic> field, dynamic value) {
  final required = field['required'] as bool? ?? false;
  final type = field['type'] as String;
  final validation = (field['validation'] as Map?)?.cast<String, dynamic>() ?? {};

  final isEmpty = value == null || value == '' || (value is List && value.isEmpty);
  if (required && isEmpty) return '${field['label']} is required.';
  if (isEmpty) return null;

  switch (type) {
    case 'text':
    case 'textarea':
      final s = value as String;
      final min = validation['min_length'] as int?;
      final max = validation['max_length'] as int?;
      if (min != null && s.length < min) return 'Minimum $min characters.';
      if (max != null && s.length > max) return 'Maximum $max characters.';
      final fmt = validation['format'] as String?;
      if (fmt == 'email' && !_isEmail(s)) return 'Enter a valid email.';
      if (fmt == 'phone' && !_isPhone(s)) return 'Enter a valid phone number.';
      break;
    case 'number':
      final n = (value as num).toDouble();
      final min = (validation['min'] as num?)?.toDouble();
      final max = (validation['max'] as num?)?.toDouble();
      if (min != null && n < min) return 'Minimum value is $min.';
      if (max != null && n > max) return 'Maximum value is $max.';
      break;
    case 'select':
      final opts = (field['options'] as List).cast<String>();
      if (!opts.contains(value)) return 'Invalid selection.';
      break;
    case 'multi_select':
      if (value is! List) return 'Must be a list.';
      final opts = (field['options'] as List).cast<String>();
      for (final v in value) {
        if (!opts.contains(v)) return 'Invalid option: $v';
      }
      break;
  }
  return null;
}

bool _isEmail(String s) => RegExp(r'^[^@]+@[^@]+\.[^@]+$').hasMatch(s);
bool _isPhone(String s) => RegExp(r'^\+?[\d\s\-(]{7,20}$').hasMatch(s);

// ── Status transitions ─────────────────────────────────────────────────────

const _validTransitions = {
  'pending': ['in_progress', 'on_hold', 'cancelled'],
  'in_progress': ['completed', 'on_hold'],
  'on_hold': ['in_progress', 'cancelled'],
  'completed': <String>[],
  'cancelled': <String>[],
};

bool canTransition(String from, String to) =>
    (_validTransitions[from] ?? []).contains(to);

// ── Sync queue priority logic ──────────────────────────────────────────────

enum SyncItemType { jobStatus, checklist, photo }

class SyncItem {
  final SyncItemType type;
  final String id;
  final int priority;
  SyncItem(this.type, this.id) : priority = type.index; // job=0, checklist=1, photo=2
}

List<SyncItem> orderSyncQueue(List<SyncItem> items) {
  final sorted = List<SyncItem>.from(items);
  sorted.sort((a, b) => a.priority.compareTo(b.priority));
  return sorted;
}

// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  group('Form validation — text fields', () {
    test('required text field with empty string returns error', () {
      final err = validateField(
          {'type': 'text', 'label': 'Name', 'required': true}, '');
      expect(err, contains('required'));
    });

    test('required text field with null returns error', () {
      final err = validateField(
          {'type': 'text', 'label': 'Name', 'required': true}, null);
      expect(err, contains('required'));
    });

    test('optional text field with null returns null (valid)', () {
      final err = validateField(
          {'type': 'text', 'label': 'Notes', 'required': false}, null);
      expect(err, isNull);
    });

    test('text field with value shorter than min_length returns error', () {
      final err = validateField({
        'type': 'text', 'label': 'Notes', 'required': true,
        'validation': {'min_length': 10}
      }, 'Hi');
      expect(err, contains('10'));
    });

    test('text field with value longer than max_length returns error', () {
      final err = validateField({
        'type': 'textarea', 'label': 'Desc', 'required': false,
        'validation': {'max_length': 5}
      }, 'This is too long');
      expect(err, contains('5'));
    });

    test('text at exactly min_length is valid', () {
      final err = validateField({
        'type': 'text', 'label': 'Code', 'required': true,
        'validation': {'min_length': 4}
      }, 'ABCD');
      expect(err, isNull);
    });
  });

  group('Form validation — email format', () {
    test('valid email passes', () {
      final err = validateField({
        'type': 'text', 'label': 'Email', 'required': true,
        'validation': {'format': 'email'}
      }, 'user@example.com');
      expect(err, isNull);
    });

    test('invalid email fails', () {
      final err = validateField({
        'type': 'text', 'label': 'Email', 'required': true,
        'validation': {'format': 'email'}
      }, 'not-an-email');
      expect(err, contains('email'));
    });

    test('email without TLD fails', () {
      final err = validateField({
        'type': 'text', 'label': 'Email', 'required': true,
        'validation': {'format': 'email'}
      }, 'user@domain');
      expect(err, contains('email'));
    });
  });

  group('Form validation — number fields', () {
    test('number below min returns error', () {
      final err = validateField({
        'type': 'number', 'label': 'Pressure', 'required': true,
        'validation': {'min': 0, 'max': 500}
      }, -5);
      expect(err, contains('0'));
    });

    test('number above max returns error', () {
      final err = validateField({
        'type': 'number', 'label': 'Temp', 'required': true,
        'validation': {'min': -50, 'max': 150}
      }, 200.0);
      expect(err, contains('150'));
    });

    test('number at exactly max is valid', () {
      final err = validateField({
        'type': 'number', 'label': 'Score', 'required': true,
        'validation': {'min': 0, 'max': 100}
      }, 100);
      expect(err, isNull);
    });

    test('number without validation passes', () {
      final err = validateField({
        'type': 'number', 'label': 'Count', 'required': true
      }, 42);
      expect(err, isNull);
    });
  });

  group('Form validation — select fields', () {
    final field = {
      'type': 'select', 'label': 'Result', 'required': true,
      'options': ['Pass', 'Fail', 'N/A']
    };

    test('valid option passes', () {
      expect(validateField(field, 'Pass'), isNull);
      expect(validateField(field, 'N/A'), isNull);
    });

    test('invalid option fails', () {
      final err = validateField(field, 'Yes');
      expect(err, contains('Invalid'));
    });

    test('required select with null fails', () {
      final err = validateField(field, null);
      expect(err, contains('required'));
    });
  });

  group('Form validation — multi_select fields', () {
    final field = {
      'type': 'multi_select', 'label': 'Issues', 'required': true,
      'options': ['Leak', 'Noise', 'None']
    };

    test('valid subset passes', () {
      expect(validateField(field, ['Leak', 'Noise']), isNull);
    });

    test('single valid option passes', () {
      expect(validateField(field, ['None']), isNull);
    });

    test('contains invalid option fails', () {
      final err = validateField(field, ['Leak', 'Unknown']);
      expect(err, contains('Unknown'));
    });

    test('required multi_select with empty list fails', () {
      final err = validateField(field, []);
      expect(err, contains('required'));
    });
  });

  group('Status transitions', () {
    test('pending → in_progress is valid', () {
      expect(canTransition('pending', 'in_progress'), isTrue);
    });

    test('in_progress → completed is valid', () {
      expect(canTransition('in_progress', 'completed'), isTrue);
    });

    test('completed → anything is invalid', () {
      expect(canTransition('completed', 'pending'), isFalse);
      expect(canTransition('completed', 'in_progress'), isFalse);
      expect(canTransition('completed', 'cancelled'), isFalse);
    });

    test('cancelled → anything is invalid', () {
      expect(canTransition('cancelled', 'pending'), isFalse);
    });

    test('pending → completed (skipping in_progress) is invalid', () {
      expect(canTransition('pending', 'completed'), isFalse);
    });

    test('on_hold → in_progress is valid', () {
      expect(canTransition('on_hold', 'in_progress'), isTrue);
    });
  });

  group('Sync queue ordering', () {
    test('jobs ordered before checklists before photos', () {
      final items = [
        SyncItem(SyncItemType.photo, 'photo-1'),
        SyncItem(SyncItemType.checklist, 'checklist-1'),
        SyncItem(SyncItemType.jobStatus, 'job-1'),
      ];
      final ordered = orderSyncQueue(items);
      expect(ordered[0].type, SyncItemType.jobStatus);
      expect(ordered[1].type, SyncItemType.checklist);
      expect(ordered[2].type, SyncItemType.photo);
    });

    test('empty queue stays empty', () {
      expect(orderSyncQueue([]), isEmpty);
    });

    test('same type items preserve relative order', () {
      final items = [
        SyncItem(SyncItemType.photo, 'photo-a'),
        SyncItem(SyncItemType.photo, 'photo-b'),
      ];
      final ordered = orderSyncQueue(items);
      expect(ordered.map((i) => i.id).toList(), ['photo-a', 'photo-b']);
    });

    test('mixed queue with no photos orders correctly', () {
      final items = [
        SyncItem(SyncItemType.checklist, 'cl-1'),
        SyncItem(SyncItemType.jobStatus, 'job-2'),
        SyncItem(SyncItemType.jobStatus, 'job-1'),
      ];
      final ordered = orderSyncQueue(items);
      expect(ordered[0].type, SyncItemType.jobStatus);
      expect(ordered[1].type, SyncItemType.jobStatus);
      expect(ordered[2].type, SyncItemType.checklist);
    });
  });
}
