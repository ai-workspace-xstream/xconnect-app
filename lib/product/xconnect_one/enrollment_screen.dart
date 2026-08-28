import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import 'mobile_enrollment.dart';

final class XConnectOneEnrollmentScreen extends StatefulWidget {
  const XConnectOneEnrollmentScreen({required this.controller, super.key});

  final XConnectOneEnrollmentController controller;

  @override
  State<XConnectOneEnrollmentScreen> createState() =>
      _XConnectOneEnrollmentScreenState();
}

final class _XConnectOneEnrollmentScreenState
    extends State<XConnectOneEnrollmentScreen> {
  final TextEditingController _inviteInput = TextEditingController();

  @override
  void dispose() {
    _inviteInput.clear();
    _inviteInput.dispose();
    super.dispose();
  }

  Future<void> _importPaste() async {
    final value = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (value == null) return;
    await widget.controller.submitPayload(
      value,
      source: XConnectOneInviteSource.paste,
    );
  }

  Future<void> _submitText() async {
    final value = _inviteInput.text;
    _inviteInput.clear();
    await widget.controller.submitPayload(
      value,
      source: XConnectOneInviteSource.paste,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.get('xconnectOneJoinTitle'))),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) {
            final state = widget.controller.state;
            final busy =
                state.phase == XConnectOneEnrollmentPhase.checkingHost ||
                    state.phase == XConnectOneEnrollmentPhase.joining ||
                    state.phase == XConnectOneEnrollmentPhase.clearing;
            return ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(context.l10n.get('xconnectOneJoinDescription')),
                const SizedBox(height: 20),
                TextField(
                  controller: _inviteInput,
                  enabled: !busy,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: context.l10n.get('xconnectOneInviteLabel'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: busy ? null : _submitText,
                      child: Text(context.l10n.get('xconnectOneImport')),
                    ),
                    OutlinedButton(
                      onPressed: busy ? null : _importPaste,
                      child: Text(context.l10n.get('xconnectOnePaste')),
                    ),
                    OutlinedButton(
                      onPressed: busy ? null : widget.controller.scanQr,
                      child: Text(context.l10n.get('xconnectOneScanQr')),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  '${context.l10n.get('xconnectOneStatus')}: ${state.code}',
                  key: const Key('xconnect-one-status'),
                ),
                const SizedBox(height: 12),
                if (state.phase == XConnectOneEnrollmentPhase.inviteReady)
                  FilledButton.icon(
                    onPressed: widget.controller.join,
                    icon: const Icon(Icons.lock_outline),
                    label: Text(context.l10n.get('xconnectOneJoin')),
                  ),
                if (state.retryable ||
                    state.phase == XConnectOneEnrollmentPhase.recoveryRequired)
                  OutlinedButton(
                    onPressed: busy ? null : widget.controller.retry,
                    child: Text(context.l10n.get('xconnectOneRetry')),
                  ),
                TextButton(
                  onPressed: state.phase == XConnectOneEnrollmentPhase.clearing
                      ? null
                      : widget.controller.clear,
                  child: Text(context.l10n.get('xconnectOneClear')),
                ),
                const SizedBox(height: 12),
                Text(
                  context.l10n.get('xconnectOneRuntimeBoundary'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
