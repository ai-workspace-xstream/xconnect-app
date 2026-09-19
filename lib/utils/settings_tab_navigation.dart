/// Stable identity for a tab in [SettingsScreen]'s tab strip.
///
/// The strip filters out tabs whose blocks are empty on the current
/// platform (e.g. iOS has no desktop DNS group), so a tab's position in the
/// rendered list shifts between platforms. Anything that links to a specific
/// tab — e.g. a diagnosis verdict pointing at its repair — must target one of
/// these ids, never a raw index.
enum SettingsTabId {
  connection,
  dns,
  routing,
  transport,
  config,
  system,
  diagnostics,
  repair,
}

/// A request to switch the Settings screen to a specific tab.
///
/// Published on [GlobalState.settingsTabRequest] and consumed once by
/// [SettingsScreen], which resets the notifier to null after acting on it.
class SettingsTabRequest {
  const SettingsTabRequest({required this.id});

  final SettingsTabId id;
}

/// Finds where [requested] sits within [visible], the tab ids currently
/// rendered after platform filtering.
///
/// Returns null rather than falling back to index 0 when the platform has
/// filtered the requested tab out entirely, so a caller can tell "landed on
/// the wrong tab" apart from "landed on the requested tab, which happens to
/// be first".
int? resolveSettingsTabIndex(
  List<SettingsTabId> visible,
  SettingsTabId requested,
) {
  final index = visible.indexOf(requested);
  return index == -1 ? null : index;
}
