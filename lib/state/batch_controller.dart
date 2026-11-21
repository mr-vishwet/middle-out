
import 'package:flutter/foundation.dart';

import '../codec/encoder.dart';
import '../codec/frame.dart';
import '../codec/pdf_document.dart';
import '../codec/streaming_encoder.dart';
import '../services/file_picker_service.dart';
import '../services/file_reader.dart';
import '../services/platform_limits.dart';
import '../services/share_service.dart';
import '../services/storage_service.dart';
import 'encode_controller.dart';
import 'history_store.dart';

/// Where a batch item is.
enum BatchStatus {
  /// Waiting to run.
  queued,

  /// Encoding now.
  encoding,

  /// Encoded; the PDF is ready.
  done,

  /// Failed — see [BatchItem.error].
  error,

  /// Cancelled before it ran.
  cancelled,
}

/// One file in the batch queue, with its own settings.
///
/// Passphrases and file bytes live in memory only and are never
/// persisted; the persisted queue (path-based items on native) reloads
/// with default settings.
class BatchItem {
  /// Creates a batch item.
  const BatchItem({
    required this.id,
    required this.name,
    required this.size,
    this.path,
    this.bytes,
    this.barcode = false,
    this.encrypted = true,
    this.passphrase = '',
    this.status = BatchStatus.queued,
    this.progress = 0,
    this.progressLabel = '',
    this.result,
    this.pdfBytes,
    this.pdfStats,
    this.error,
  });

  /// Stable id.
  final String id;

  /// File name.
  final String name;

  /// File size in bytes.
  final int size;

  /// Native file path (null on web).
  final String? path;

  /// File bytes (web picks; native items read from [path]).
  final Uint8List? bytes;

  /// This item's code format (false = QR grid).
  final bool barcode;

  /// This item's encryption toggle.
  final bool encrypted;

  /// This item's passphrase (memory only, never persisted).
  final String passphrase;

  /// Current status.
  final BatchStatus status;

  /// Encode progress 0..1.
  final double progress;

  /// Human-readable progress label.
  final String progressLabel;

  /// Encode result (when done).
  final EncodeResult? result;

  /// Assembled PDF bytes (when done).
  final Uint8List? pdfBytes;

  /// PDF statistics (when done).
  final PdfStats? pdfStats;

  /// Error message (when [status] is [BatchStatus.error]).
  final String? error;

  /// Creates a copy with the given fields replaced.
  BatchItem copyWith({
    bool? barcode,
    bool? encrypted,
    String? passphrase,
    BatchStatus? status,
    double? progress,
    String? progressLabel,
    EncodeResult? result,
    Uint8List? pdfBytes,
    PdfStats? pdfStats,
    String? error,
    bool clearError = false,
  }) =>
      BatchItem(
        id: id,
        name: name,
        size: size,
        path: path,
        bytes: bytes,
        barcode: barcode ?? this.barcode,
        encrypted: encrypted ?? this.encrypted,
        passphrase: passphrase ?? this.passphrase,
        status: status ?? this.status,
        progress: progress ?? this.progress,
        progressLabel: progressLabel ?? this.progressLabel,
        result: result ?? this.result,
        pdfBytes: pdfBytes ?? this.pdfBytes,
        pdfStats: pdfStats ?? this.pdfStats,
        error: clearError ? null : (error ?? this.error),
      );

  /// Creates an item from a picked reference with default settings.
  factory BatchItem.fromRef(
    PickedRef ref, {
    bool barcode = false,
    bool encrypted = true,
  }) =>
      BatchItem(
        id: HistoryRecord.newId(),
        name: ref.name,
        size: ref.size,
        path: ref.path,
        bytes: ref.bytes,
        barcode: barcode,
        encrypted: encrypted,
      );

  /// Serialises the item's metadata (no bytes, no passphrase).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'size': size,
        'path': path,
        'barcode': barcode,
        'encrypted': encrypted,
      };

  /// Parses persisted metadata. Only path-based items survive a restart.
  factory BatchItem.fromJson(Map<String, dynamic> json) => BatchItem(
        id: json['id'] as String,
        name: json['name'] as String,
        size: json['size'] as int,
        path: json['path'] as String?,
        barcode: json['barcode'] as bool? ?? false,
        encrypted: json['encrypted'] as bool? ?? true,
      );
}

/// The batch queue: several files, each with its own settings, encoded
/// in order. Runs sequentially so memory stays bounded; each finished
/// item records history and keeps its PDF for save/share.
class BatchController extends ChangeNotifier {
  /// Creates a batch controller.
  BatchController({FilePickerService? picker})
      : _picker = picker ?? FilePickerService();

  final FilePickerService _picker;

  /// Queue items, in run order.
  List<BatchItem> items = [];

  /// True while [runAll] or [runOne] is working.
  bool running = false;

  /// True once [load] has completed.
  bool loaded = false;

  bool _cancelRequested = false;

  /// Called with the history record for each finished item.
  Future<void> Function(HistoryRecord record)? onItemDone;

  /// Items still waiting.
  List<BatchItem> get queued => [
        for (final item in items)
          if (item.status == BatchStatus.queued) item,
      ];

  /// Finished items.
  List<BatchItem> get doneItems => [
        for (final item in items)
          if (item.status == BatchStatus.done) item,
      ];

  /// Number of finished items.
  int get doneCount => doneItems.length;

  /// Total bytes across the queue.
  int get totalBytes => items.fold(0, (sum, item) => sum + item.size);

  /// Loads the persisted queue (path-based items only).
  Future<void> load() async {
    final stored =
        await StorageService.readJsonList(StorageService.batchKey);
    items = stored == null
        ? []
        : [
            for (final json in stored)
              if (json['path'] != null) BatchItem.fromJson(json),
          ];
    loaded = true;
    notifyListeners();
  }

  /// Adds files from the system picker (multi-pick, limit-gated).
  /// Returns rejection messages for over-limit files.
  Future<List<String>> addFromPicker(EncodeMode mode) async {
    final (refs, rejected) = await _picker.pickFilesMeta(mode);
    if (refs.isEmpty) return rejected;
    items = [
      ...items,
      for (final ref in refs) BatchItem.fromRef(ref),
    ];
    await _persist();
    notifyListeners();
    return rejected;
  }

  /// Adds an item directly (used by tests and by re-queue flows).
  Future<void> addItem(BatchItem item) async {
    items = [...items, item];
    await _persist();
    notifyListeners();
  }

  /// Removes an item from the queue.
  Future<void> remove(String id) async {
    items = [for (final item in items) if (item.id != id) item];
    await _persist();
    notifyListeners();
  }

  /// Removes finished items.
  Future<void> clearDone() async {
    items = [
      for (final item in items)
        if (item.status != BatchStatus.done) item,
    ];
    await _persist();
    notifyListeners();
  }

  /// Removes every item.
  Future<void> clearAll() async {
    items = [];
    await _persist();
    notifyListeners();
  }

  /// Updates one item's per-item settings.
  void updateOptions(
    String id, {
    bool? barcode,
    bool? encrypted,
    String? passphrase,
  }) {
    items = [
      for (final item in items)
        if (item.id == id)
          item.copyWith(
            barcode: barcode,
            encrypted: encrypted,
            passphrase: passphrase,
          )
        else
          item,
    ];
    notifyListeners();
  }

  /// Runs every queued item in order. Stops early when [cancel] is called.
  Future<void> runAll() async {
    if (running) return;
    running = true;
    _cancelRequested = false;
    notifyListeners();
    for (final item in List<BatchItem>.from(queued)) {
      if (_cancelRequested) break;
      await runOne(item.id);
    }
    running = false;
    await _persist();
    notifyListeners();
  }

  /// Runs one item by id.
  Future<void> runOne(String id) async {
    final index = items.indexWhere((item) => item.id == id);
    if (index < 0) return;
    var item = items[index];
    if (item.status == BatchStatus.encoding) return;
    if (item.encrypted && item.passphrase.isEmpty) {
      _update(
        item.copyWith(
          status: BatchStatus.error,
          error: 'Encryption is on — set a passphrase, or turn it off.',
        ),
      );
      return;
    }
    _update(
      item.copyWith(
        status: BatchStatus.encoding,
        progress: 0,
        progressLabel: 'Starting…',
        clearError: true,
      ),
    );
    item = items[index];
    try {
      final useStreaming = !kIsWeb &&
          StreamingEncoder.isSupported &&
          item.path != null &&
          item.size >= EncodeController.streamingThresholdBytes;
      final EncodeResult encoded;
      if (useStreaming) {
        encoded = await StreamingEncoder.encodeFile(
          path: item.path!,
          passphrase: item.encrypted ? item.passphrase : null,
          barcode: item.barcode,
          onProgress: (fraction, label) {
            _update(
              items[index].copyWith(
                progress: fraction * 0.8,
                progressLabel: label,
              ),
            );
          },
        );
      } else {
        final Uint8List bytes;
        if (item.bytes != null) {
          bytes = item.bytes!;
        } else if (item.path != null) {
          bytes = await readPickedFile(item.path!);
        } else {
          throw const CodecException('No file data for this item.');
        }
        _update(
          items[index].copyWith(progress: 0.4, progressLabel: 'Compressing…'),
        );
        encoded = Encoder.encode(
          bytes,
          passphrase: item.encrypted ? item.passphrase : null,
          barcode: item.barcode,
        );
      }
      _update(
        items[index].copyWith(
          progress: 0.85,
          progressLabel: 'Building PDF…',
        ),
      );
      final (pdf, stats) = await PdfDocument.build(encoded, item.name);
      _update(
        items[index].copyWith(
          status: BatchStatus.done,
          progress: 1,
          progressLabel: 'Done',
          result: encoded,
          pdfBytes: pdf,
          pdfStats: stats,
        ),
      );
      await onItemDone?.call(
        HistoryRecord(
          id: HistoryRecord.newId(),
          kind: HistoryKind.encode,
          fileName: item.name,
          originalBytes: encoded.stats.originalSize,
          encodedBytes: encoded.stats.compressedSize,
          frameCount: encoded.stats.frameCount,
          groupCount: encoded.stats.groupCount,
          barcode: item.barcode,
          encrypted: item.encrypted,
          sha256Hex: encoded.stats.sha256Hex,
          createdAt: DateTime.now(),
        ),
      );
    } on CodecException catch (e) {
      _update(
        items[index].copyWith(
          status: BatchStatus.error,
          error: e.message,
        ),
      );
    } catch (e) {
      _update(
        items[index].copyWith(
          status: BatchStatus.error,
          error: 'Encode failed: $e',
        ),
      );
    }
    await _persist();
    notifyListeners();
  }

  /// Asks a running batch to stop after the current item.
  void cancel() {
    _cancelRequested = true;
    notifyListeners();
  }

  /// Shares a finished item's PDF through the system share sheet.
  Future<void> shareItemPdf(String id) async {
    final index = items.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final item = items[index];
    if (item.pdfBytes == null) return;
    await ShareService.sharePdf(
      item.pdfBytes!,
      '${item.name}.middleout.pdf',
    );
  }

  void _update(BatchItem next) {
    items = [
      for (final item in items)
        if (item.id == next.id) next else item,
    ];
    notifyListeners();
  }

  Future<void> _persist() async {
    await StorageService.writeJsonList(
      StorageService.batchKey,
      [for (final item in items) item.toJson()],
    );
  }
}
