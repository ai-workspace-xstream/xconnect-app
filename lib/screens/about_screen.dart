import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/global_config.dart';
import '../widgets/app_breadcrumb.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key, this.breadcrumbItems});

  final List<String>? breadcrumbItems;

  static const _githubUrl =
      'https://github.com/ai-workspace-xstream/xconnect-app';

  Future<void> _openGithub() async {
    final uri = Uri.parse(_githubUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Widget _buildBody(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (snapshot.hasData)
                      Text(
                        'v${snapshot.data!.version}+${snapshot.data!.buildNumber}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    Text(
                      buildVersion,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).disabledColor,
                          ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            const Text('© 2025-2026 svc.plus'),
            const SizedBox(height: 4),
            Text(
              'XConnect is a client-only, self-hosted connector app. '
              'Optional workspace sync, when enabled, is provided by svc.plus.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).disabledColor,
                  ),
            ),
            const SizedBox(height: 16),
            InkWell(
              onTap: _openGithub,
              child: Text(
                'Open source on GitHub: $_githubUrl',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      decoration: TextDecoration.underline,
                    ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'XConnect is licensed under the Apache License 2.0.\n\n'
              'This application includes components from:\n'
              '• Xray-core v26.2.6 (12ee51e, go1.25.7 darwin/arm64)\n'
              '  Xray, high-performance secure tunnel engine.\n'
              '  https://github.com/XTLS/Xray-core\n'
              '  Licensed under the Mozilla Public License 2.0',
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // When breadcrumbItems is provided, this screen is pushed standalone
    // (e.g. from SettingsScreen) and needs its own AppBar.
    // When null, it is embedded in MainPage which already has a top AppBar.
    if (breadcrumbItems != null) {
      return Scaffold(
        appBar: AppBar(title: AppBreadcrumb(items: breadcrumbItems!)),
        body: _buildBody(context),
      );
    }
    return _buildBody(context);
  }
}
