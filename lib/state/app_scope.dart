import 'package:material_ui/material_ui.dart';

import 'auth_controller.dart';
import 'batch_controller.dart';
import 'encode_controller.dart';
import 'history_store.dart';
import 'link_store.dart';
import 'settings_controller.dart';

/// The app's shared state: one instance of every controller, wired
/// together and owned by the app shell.
///
/// Encode, decode and batch completions record history automatically;
/// settings seed the encode defaults at startup.
class AppState {
  /// Creates the app state and wires the history callbacks.
  AppState() {
    encode.onEncoded = history.add;
    decode.onDecoded = history.add;
    batch.onItemDone = history.add;
  }

  /// Encode + decode flow state.
  final EncodeController encode = EncodeController();

  /// Decode flow state.
  final DecodeController decode = DecodeController();

  /// Batch queue state.
  final BatchController batch = BatchController();

  /// History store.
  final HistoryStore history = HistoryStore();

  /// Settings.
  final SettingsController settings = SettingsController();

  /// Auth + account state.
  final AuthController auth = AuthController();

  /// Shared links.
  final LinkStore links = LinkStore();

  /// True once [init] has completed.
  bool initialized = false;

  /// Loads all persisted state and applies settings to the encode flow.
  Future<void> init() async {
    await settings.load();
    await history.load();
    await auth.load();
    await batch.load();
    await links.load();
    encode.applySettings(settings);
    initialized = true;
  }

  /// Disposes every controller.
  void dispose() {
    encode.dispose();
    decode.dispose();
    batch.dispose();
    history.dispose();
    settings.dispose();
    auth.dispose();
    links.dispose();
  }
}

/// Provides [AppState] to the widget tree.
///
/// Screens read state with `AppScope.of(context)`; controllers are
/// listened to with [ListenableBuilder] so only the screens that need a
/// controller rebuild when it changes.
class AppScope extends InheritedWidget {
  /// Creates an app scope holding [state].
  const AppScope({required this.state, required super.child, super.key});

  /// The shared app state.
  final AppState state;

  /// Returns the app state from the nearest [AppScope] ancestor.
  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'No AppScope found in the widget tree.');
    return scope!.state;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => state != oldWidget.state;
}
