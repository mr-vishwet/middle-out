/// Named routes for the whole app — one route per V7 screen concept.
///
/// Each route renders adaptively: the mobile layout below 800 px logical
/// width and the web layout above it (see [Adaptive] in `adaptive.dart`),
/// so these 30 routes cover all 60 V7 screens (m01–m30 + w01–w30).
/// The route table itself lives in `app.dart` ([generateAppRoute]); this
/// file holds only the names so screens can navigate without importing
/// the app shell.
///
/// Route arguments:
/// * [frameDetail] takes an `int` frame index into the current encode.
/// * [historyDetail] takes a `String` history-record id.
/// * [authUpgrade] takes an optional `int` file size in bytes.
library;

abstract final class AppRoutes {
  /// m01/w01 — home dashboard (also the shell's Home tab).
  static const String home = '/';

  /// m02/w02 — file picker (also the shell's Encode tab).
  static const String encodePick = '/encode/pick';

  /// m03/w03 — pre-encode: estimate + format/encryption toggles.
  static const String encodePre = '/encode/pre';

  /// m04/w04 — encoding progress.
  static const String encodeProgress = '/encode/progress';

  /// m05/w05 — encode result: ratio, frames, hash, PDF size, save/share.
  static const String encodeResult = '/encode/result';

  /// m06/w06 — frames view: data + parity frames of the current encode.
  static const String frames = '/frames';

  /// m07/w07 — one frame at full size. Argument: `int` frame index.
  static const String frameDetail = '/frames/detail';

  /// m08/w08 — the encoded PDF: cover + code pages.
  static const String pdfPreview = '/pdf';

  /// m09/w09 — share sheet: PDF file, expiring link, save to Files.
  static const String share = '/share';

  /// m10/w10 — batch queue.
  static const String batch = '/batch';

  /// m11/w11 — history (also the shell's History tab).
  static const String history = '/history';

  /// m12/w12 — one history record. Argument: `String` record id.
  static const String historyDetail = '/history/detail';

  /// m13/w13 — decode entry (also the shell's Decode tab).
  static const String decode = '/decode';

  /// m14/w14 — decode import: frames verified before decode starts.
  static const String decodeImport = '/decode/import';

  /// m15/w15 — decoding progress.
  static const String decodeProgress = '/decode/progress';

  /// m16/w16 — verify: expected vs rebuilt SHA-256, side by side.
  static const String decodeVerify = '/decode/verify';

  /// m17/w17 — decoded: the original is back, verified bit-for-bit.
  static const String decoded = '/decode/done';

  /// m18/w18 — damaged frame: what parity rebuilt.
  static const String decodeDamaged = '/decode/damaged';

  /// Camera scan (extra route feeding decode entry; not one of the 30).
  static const String decodeScan = '/decode/scan';

  /// m19/w19 — settings: limits, defaults, display, data.
  static const String settings = '/settings';

  /// m20/w20 — the payoff: send small, open big.
  static const String payoff = '/payoff';

  /// m21/w21 — welcome: guest-first, sign in optional.
  static const String authWelcome = '/auth/welcome';

  /// m22/w22 — guest mode, explained.
  static const String authGuest = '/auth/guest';

  /// m23/w23 — sign in.
  static const String authSignIn = '/auth/sign-in';

  /// m24/w24 — create account.
  static const String authCreate = '/auth/create';

  /// m25/w25 — verify: magic link or 6-digit code.
  static const String authVerify = '/auth/verify';

  /// m26/w26 — upgrade prompt: the file needs cloud encode.
  /// Argument: optional `int` file size in bytes.
  static const String authUpgrade = '/auth/upgrade';

  /// m27/w27 — migrate guest work into the account.
  static const String authMigrate = '/auth/migrate';

  /// m28/w28 — account home (also the shell's Account tab when signed in).
  static const String account = '/account';

  /// m29/w29 — connected: shared links, cloud storage, sign-in methods.
  static const String accountConnected = '/account/connected';

  /// m30/w30 — data controls: export, sign out, delete account.
  static const String accountData = '/account/data';

  /// All 30 V7 routes, in screen order.
  static const List<String> all = [
    home,
    encodePick,
    encodePre,
    encodeProgress,
    encodeResult,
    frames,
    frameDetail,
    pdfPreview,
    share,
    batch,
    history,
    historyDetail,
    decode,
    decodeImport,
    decodeProgress,
    decodeVerify,
    decoded,
    decodeDamaged,
    settings,
    payoff,
    authWelcome,
    authGuest,
    authSignIn,
    authCreate,
    authVerify,
    authUpgrade,
    authMigrate,
    account,
    accountConnected,
    accountData,
  ];
}
