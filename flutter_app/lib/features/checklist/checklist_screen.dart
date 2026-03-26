import 'dart:convert';
import 'dart:io';
import 'dart:async'; 
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/storage/app_database.dart';
import '../photo/photo_capture.dart';
import '../signature/signature_screen.dart';

part 'checklist_screen.g.dart';

// ── State ─────────────────────────────────────────────────────────────────

@riverpod
class ChecklistFormNotifier extends _$ChecklistFormNotifier {
  late String _jobId;
  late List<Map<String, dynamic>> _fields;

  @override
  ChecklistFormState build(String jobId) {
    _jobId = jobId;
    _loadDraft();
    return const ChecklistFormState(answers: {}, errors: {}, isDirty: false);
  }

  Future<void> init(List<Map<String, dynamic>> fields) async {
    _fields = fields;
  }

  Future<void> _loadDraft() async {
    final db = ref.read(appDatabaseProvider);
    final draft = await db.getDraft(_jobId);
    if (draft != null) {
      final answers = jsonDecode(draft.answersJson) as Map<String, dynamic>;
      state = state.copyWith(answers: answers);
    }
  }

  void setAnswer(String fieldId, dynamic value) {
    final answers = Map<String, dynamic>.from(state.answers);
    answers[fieldId] = value;
    // Clear error on change
    final errors = Map<String, String>.from(state.errors);
    errors.remove(fieldId);
    state = state.copyWith(answers: answers, errors: errors, isDirty: true);
    _autosave();
  }

  Timer? _saveTimer;
  void _autosave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), () => saveDraft());
  }

  Future<void> saveDraft() async {
    final db = ref.read(appDatabaseProvider);
    await db.upsertDraft(ChecklistDraftsCompanion(
      jobId: Value(_jobId),
      schemaId: const Value(''),
      answersJson: Value(jsonEncode(state.answers)),
      status: const Value('draft'),
      updatedAt: Value(DateTime.now()),
      pendingSync: const Value(true),
    ));
    state = state.copyWith(isDirty: false, lastSaved: DateTime.now());
  }

  /// Validate all fields. Returns true if valid.
  bool validate() {
    final errors = <String, String>{};
    for (final field in _fields) {
      final error = _validateField(field, state.answers[field['id']]);
      if (error != null) errors[field['id'] as String] = error;
    }
    state = state.copyWith(errors: errors);
    return errors.isEmpty;
  }

  String? _validateField(Map<String, dynamic> field, dynamic value) {
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
      case 'number':
        final n = (value as num).toDouble();
        final min = (validation['min'] as num?)?.toDouble();
        final max = (validation['max'] as num?)?.toDouble();
        if (min != null && n < min) return 'Minimum value is $min.';
        if (max != null && n > max) return 'Maximum value is $max.';
      case 'select':
        final opts = (field['options'] as List).cast<String>();
        if (!opts.contains(value)) return 'Invalid selection.';
    }
    return null;
  }

  Future<bool> submit() async {
    if (!validate()) return false;
    final db = ref.read(appDatabaseProvider);
    await db.upsertDraft(ChecklistDraftsCompanion(
      jobId: Value(_jobId),
      schemaId: const Value(''),
      answersJson: Value(jsonEncode(state.answers)),
      status: const Value('submitted'),
      updatedAt: Value(DateTime.now()),
      pendingSync: const Value(true),
    ));
    return true;
  }

  bool _isEmail(String s) => RegExp(r'^[^@]+@[^@]+\.[^@]+$').hasMatch(s);
  bool _isPhone(String s) => RegExp(r'^\+?[\d\s\-(]{7,20}$').hasMatch(s);
}

class ChecklistFormState {
  final Map<String, dynamic> answers;
  final Map<String, String> errors;
  final bool isDirty;
  final DateTime? lastSaved;

  const ChecklistFormState({
    required this.answers,
    required this.errors,
    required this.isDirty,
    this.lastSaved,
  });

  ChecklistFormState copyWith({
    Map<String, dynamic>? answers,
    Map<String, String>? errors,
    bool? isDirty,
    DateTime? lastSaved,
  }) =>
      ChecklistFormState(
        answers: answers ?? this.answers,
        errors: errors ?? this.errors,
        isDirty: isDirty ?? this.isDirty,
        lastSaved: lastSaved ?? this.lastSaved,
      );
}

// ── Screen ────────────────────────────────────────────────────────────────

class ChecklistScreen extends ConsumerStatefulWidget {
  final String jobId;
  final Map<String, dynamic> schema;

  const ChecklistScreen({super.key, required this.jobId, required this.schema});

  @override
  ConsumerState<ChecklistScreen> createState() => _ChecklistScreenState();
}

class _ChecklistScreenState extends ConsumerState<ChecklistScreen> {
  final _scrollCtrl = ScrollController();
  final _fieldKeys = <String, GlobalKey>{};
  bool _isSubmitting = false;

  List<Map<String, dynamic>> get _fields =>
      (widget.schema['fields'] as List).cast<Map<String, dynamic>>()
        ..sort((a, b) => (a['order'] as int? ?? 0).compareTo(b['order'] as int? ?? 0));

  @override
  void initState() {
    super.initState();
    for (final f in _fields) {
      _fieldKeys[f['id'] as String] = GlobalKey();
    }
    ref.read(checklistFormNotifierProvider(widget.jobId).notifier).init(_fields);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _isSubmitting = true);
    try {
      final notifier = ref.read(checklistFormNotifierProvider(widget.jobId).notifier);
      final ok = await notifier.submit();
      if (!ok) {
        // Scroll to first error
        final state = ref.read(checklistFormNotifierProvider(widget.jobId));
        _scrollToFirstError(state.errors);
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Checklist submitted! Will sync when online.'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _scrollToFirstError(Map<String, String> errors) {
    if (errors.isEmpty) return;
    // Find the earliest field (by order) with an error
    final errorFieldId = _fields
        .where((f) => errors.containsKey(f['id']))
        .map((f) => f['id'] as String)
        .firstOrNull;
    if (errorFieldId == null) return;

    final key = _fieldKeys[errorFieldId];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
        alignment: 0.1,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final formState = ref.watch(checklistFormNotifierProvider(widget.jobId));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.schema['name'] as String? ?? 'Checklist'),
        actions: [
          TextButton(
            onPressed: () => ref
                .read(checklistFormNotifierProvider(widget.jobId).notifier)
                .saveDraft(),
            child: const Text('Save Draft'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (formState.lastSaved != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              color: Colors.green.shade50,
              child: Text(
                'Draft saved ${DateFormat('h:mm a').format(formState.lastSaved!)}',
                style: TextStyle(fontSize: 12, color: Colors.green.shade700),
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: ListView(
              controller: _scrollCtrl,
              padding: const EdgeInsets.all(16),
              children: [
                ..._fields.map((field) {
                  final id = field['id'] as String;
                  return Padding(
                    key: _fieldKeys[id],
                    padding: const EdgeInsets.only(bottom: 20),
                    child: _buildField(
                      field,
                      formState.answers[id],
                      formState.errors[id],
                    ),
                  );
                }),
                const SizedBox(height: 8),
                if (formState.errors.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${formState.errors.length} field(s) require attention.',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer),
                    ),
                  ),
                FilledButton(
                  onPressed: _isSubmitting ? null : _submit,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Submit Checklist', style: TextStyle(fontSize: 16)),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildField(Map<String, dynamic> field, dynamic value, String? error) {
    final type = field['type'] as String;
    final label = field['label'] as String;
    final required = field['required'] as bool? ?? false;
    final helpText = field['help_text'] as String?;

    Widget fieldWidget = switch (type) {
      'text' => _TextField(field: field, value: value as String?, error: error,
          onChanged: (v) => _setAnswer(field['id'] as String, v)),
      'textarea' => _TextAreaField(field: field, value: value as String?, error: error,
          onChanged: (v) => _setAnswer(field['id'] as String, v)),
      'number' => _NumberField(field: field, value: value, error: error,
          onChanged: (v) => _setAnswer(field['id'] as String, v)),
      'select' => _SelectField(field: field, value: value as String?, error: error,
          onChanged: (v) => _setAnswer(field['id'] as String, v)),
      'multi_select' => _MultiSelectField(field: field,
          value: (value as List?)?.cast<String>() ?? [], error: error,
          onChanged: (v) => _setAnswer(field['id'] as String, v)),
      'datetime' => _DateTimeField(field: field, value: value as String?, error: error,
          onChanged: (v) => _setAnswer(field['id'] as String, v)),
      'checkbox' => _CheckboxField(field: field, value: value as bool? ?? false,
          onChanged: (v) => _setAnswer(field['id'] as String, v)),
      'photo' => _PhotoField(jobId: widget.jobId, field: field,
          value: (value as List?)?.cast<String>() ?? [],
          onChanged: (v) => _setAnswer(field['id'] as String, v)),
      'signature' => _SignatureField(jobId: widget.jobId, field: field,
          value: value as String?,
          onChanged: (v) => _setAnswer(field['id'] as String, v)),
      _ => Text('Unknown field type: $type'),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text(label,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          if (required)
            const Text(' *', style: TextStyle(color: Colors.red, fontSize: 15)),
        ]),
        if (helpText != null && helpText.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(helpText,
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).colorScheme.outline)),
        ],
        const SizedBox(height: 8),
        fieldWidget,
      ],
    );
  }

  void _setAnswer(String id, dynamic value) {
    ref.read(checklistFormNotifierProvider(widget.jobId).notifier)
        .setAnswer(id, value);
  }
}

// ── Individual field widgets ──────────────────────────────────────────────

class _TextField extends StatefulWidget {
  final Map<String, dynamic> field;
  final String? value;
  final String? error;
  final ValueChanged<String> onChanged;
  const _TextField({required this.field, this.value, this.error, required this.onChanged});

  @override
  State<_TextField> createState() => _TextFieldState();
}

class _TextFieldState extends State<_TextField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value ?? '');
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final fmt = (widget.field['validation'] as Map?)?['format'];
    return TextFormField(
      controller: _ctrl,
      onChanged: widget.onChanged,
      keyboardType: fmt == 'email'
          ? TextInputType.emailAddress
          : fmt == 'phone'
              ? TextInputType.phone
              : TextInputType.text,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        errorText: widget.error,
        hintText: widget.field['placeholder'] as String?,
        isDense: true,
      ),
    );
  }
}

class _TextAreaField extends StatefulWidget {
  final Map<String, dynamic> field;
  final String? value;
  final String? error;
  final ValueChanged<String> onChanged;
  const _TextAreaField({required this.field, this.value, this.error, required this.onChanged});

  @override
  State<_TextAreaField> createState() => _TextAreaFieldState();
}

class _TextAreaFieldState extends State<_TextAreaField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value ?? '');
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final maxLen = (widget.field['validation'] as Map?)?['max_length'] as int?;
    return TextFormField(
      controller: _ctrl,
      onChanged: widget.onChanged,
      maxLines: 4,
      maxLength: maxLen,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        errorText: widget.error,
        hintText: widget.field['placeholder'] as String?,
        alignLabelWithHint: true,
      ),
    );
  }
}

class _NumberField extends StatefulWidget {
  final Map<String, dynamic> field;
  final dynamic value;
  final String? error;
  final ValueChanged<num?> onChanged;
  const _NumberField({required this.field, this.value, this.error, required this.onChanged});

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value?.toString() ?? '');
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final v = widget.field['validation'] as Map?;
    final min = v?['min'];
    final max = v?['max'];
    return TextFormField(
      controller: _ctrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]'))],
      onChanged: (s) => widget.onChanged(num.tryParse(s)),
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        errorText: widget.error,
        hintText: min != null && max != null ? '$min – $max' : null,
        isDense: true,
      ),
    );
  }
}

class _SelectField extends StatelessWidget {
  final Map<String, dynamic> field;
  final String? value;
  final String? error;
  final ValueChanged<String?> onChanged;
  const _SelectField({required this.field, this.value, this.error, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final options = (field['options'] as List).cast<String>();
    return DropdownButtonFormField<String>(
      onChanged: onChanged,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        errorText: error,
        isDense: true,
      ),
      items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
      hint: const Text('Select an option'),
    );
  }
}

class _MultiSelectField extends StatelessWidget {
  final Map<String, dynamic> field;
  final List<String> value;
  final String? error;
  final ValueChanged<List<String>> onChanged;
  const _MultiSelectField({required this.field, required this.value, this.error, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final options = (field['options'] as List).cast<String>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8, runSpacing: 8,
          children: options.map((opt) {
            final selected = value.contains(opt);
            return FilterChip(
              label: Text(opt),
              selected: selected,
              onSelected: (checked) {
                final updated = List<String>.from(value);
                if (checked) {
                  updated.add(opt);
                } else {
                  updated.remove(opt);
                }
                onChanged(updated);
              },
            );
          }).toList(),
        ),
        if (error != null) ...[
          const SizedBox(height: 4),
          Text(error!, style: TextStyle(
              color: Theme.of(context).colorScheme.error, fontSize: 12)),
        ],
      ],
    );
  }
}

class _DateTimeField extends StatelessWidget {
  final Map<String, dynamic> field;
  final String? value;
  final String? error;
  final ValueChanged<String?> onChanged;
  const _DateTimeField({required this.field, this.value, this.error, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final parsed = value != null ? DateTime.tryParse(value!) : null;
    final display = parsed != null ? DateFormat('MMM d, y · h:mm a').format(parsed.toLocal()) : null;

    return InkWell(
      onTap: () async {
        final date = await showDatePicker(
          context: context,
          initialDate: parsed ?? DateTime.now(),
          firstDate: DateTime(2020), lastDate: DateTime(2030),
        );
        if (date == null || !context.mounted) return;
        final time = await showTimePicker(
          context: context,
          initialTime: TimeOfDay.fromDateTime(parsed ?? DateTime.now()),
        );
        if (time == null) return;
        final dt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
        onChanged(dt.toIso8601String());
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(
            color: error != null
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.outline,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            const Icon(Icons.calendar_today_outlined, size: 18),
            const SizedBox(width: 8),
            Text(display ?? 'Select date and time',
                style: TextStyle(
                  color: display != null ? null : Theme.of(context).colorScheme.outline,
                )),
          ],
        ),
      ),
    );
  }
}

class _CheckboxField extends StatelessWidget {
  final Map<String, dynamic> field;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _CheckboxField({required this.field, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Checkbox(
          value: value,
          onChanged: (v) => onChanged(v ?? false),
        ),
        const SizedBox(width: 8),
        Text(value ? 'Yes' : 'No'),
      ],
    );
  }
}

class _PhotoField extends StatelessWidget {
  final String jobId;
  final Map<String, dynamic> field;
  final List<String> value; // list of local file paths
  final ValueChanged<List<String>> onChanged;

  const _PhotoField({
    required this.jobId,
    required this.field,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final maxPhotos = field['max_photos'] as int? ?? 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8, runSpacing: 8,
          children: [
            ...value.map((path) => _PhotoThumb(
              path: path,
              onRemove: () => onChanged(value.where((p) => p != path).toList()),
            )),
            if (value.length < maxPhotos)
              _AddPhotoButton(
                onCapture: (path) => onChanged([...value, path]),
                jobId: jobId,
                fieldId: field['id'] as String,
              ),
          ],
        ),
      ],
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  final String path;
  final VoidCallback onRemove;
  const _PhotoThumb({required this.path, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(path), width: 88, height: 88, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 88, height: 88,
              color: Colors.grey.shade200,
              child: const Icon(Icons.broken_image),
            ),
          ),
        ),
        Positioned(
          top: 2, right: 2,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.black54, shape: BoxShape.circle),
              padding: const EdgeInsets.all(2),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}

class _AddPhotoButton extends StatelessWidget {
  final ValueChanged<String> onCapture;
  final String jobId;
  final String fieldId;

  const _AddPhotoButton({
    required this.onCapture,
    required this.jobId,
    required this.fieldId,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final path = await Navigator.push<String>(
          context,
          MaterialPageRoute(
            builder: (_) => PhotoCaptureScreen(jobId: jobId, fieldId: fieldId),
          ),
        );
        if (path != null) onCapture(path);
      },
      child: Container(
        width: 88, height: 88,
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outline,
            style: BorderStyle.solid,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_a_photo_outlined,
                color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 4),
            Text('Add Photo',
                style: TextStyle(
                    fontSize: 11, color: Theme.of(context).colorScheme.outline)),
          ],
        ),
      ),
    );
  }
}

class _SignatureField extends StatelessWidget {
  final String jobId;
  final Map<String, dynamic> field;
  final String? value; // local file path to signature PNG
  final ValueChanged<String?> onChanged;

  const _SignatureField({
    required this.jobId,
    required this.field,
    this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (value != null)
          Container(
            height: 100,
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.green),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(File(value!), fit: BoxFit.contain),
            ),
          )
        else
          Container(
            height: 100,
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                  style: BorderStyle.solid),
              borderRadius: BorderRadius.circular(8),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            child: Center(
              child: Text('No signature captured',
                  style: TextStyle(color: Theme.of(context).colorScheme.outline)),
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            final path = await Navigator.push<String>(
              context,
              MaterialPageRoute(builder: (_) => const SignatureScreen()),
            );
            if (path != null) onChanged(path);
          },
          icon: Icon(value != null ? Icons.refresh : Icons.draw_outlined),
          label: Text(value != null ? 'Retake Signature' : 'Capture Signature'),
        ),
      ],
    );
  }
}

// ignore: non_constant_identifier_names
extension ListExtensions<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}