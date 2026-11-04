import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../state/session.dart';

/// Three steps: the PC's address, the user name and password, and (if turned on) the two-step code.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _Step { server, password, code }

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _code = TextEditingController();
  late _Step _step;
  String? _ticket;
  String? _error;
  bool _busy = false;
  bool _showPass = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<Session>();
    _step = s.api == null ? _Step.server : _Step.password;
    _server.text = s.server.replaceFirst('http://', '');
  }

  @override
  void dispose() {
    for (final c in [_server, _user, _pass, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() job) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await job();
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _connect() => _run(() async {
        await context.read<Session>().checkServer(_server.text);
        if (mounted) setState(() => _step = _Step.password);
      });

  void _login() => _run(() async {
        if (_user.text.trim().isEmpty || _pass.text.isEmpty) throw ApiError('Type your user name and password.');
        final r = await context.read<Session>().login(_user.text, _pass.text);
        if (r.needsCode && mounted) {
          setState(() {
            _ticket = r.ticket;
            _step = _Step.code;
          });
        }
      });

  void _sendCode() => _run(() async {
        if (_code.text.trim().isEmpty) throw ApiError('Type the code from your authenticator app.');
        final r = await context.read<Session>().loginCode(_ticket!, _code.text);
        if (r.recoveryLeft != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Signed in with a recovery code. ${r.recoveryLeft} left.'),
          ));
        }
      });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final session = context.watch<Session>();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.photo_library_outlined, size: 56, color: t.colorScheme.primary),
                    const SizedBox(height: 12),
                    Text('Snapshots', textAlign: TextAlign.center, style: t.textTheme.headlineMedium),
                    const SizedBox(height: 28),
                    ..._fields(session),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: t.colorScheme.error)),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _primary,
                      child: _busy
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(switch (_step) { _Step.server => 'Connect', _Step.password => 'Sign in', _Step.code => 'Confirm' }),
                    ),
                    if (_step != _Step.server)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                  _step = _step == _Step.code ? _Step.password : _Step.server;
                                  _error = null;
                                }),
                        child: Text(_step == _Step.code ? 'Back' : 'Use another PC'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _primary() => switch (_step) { _Step.server => _connect(), _Step.password => _login(), _Step.code => _sendCode() };

  List<Widget> _fields(Session session) {
    switch (_step) {
      case _Step.server:
        return [
          Text("Your Snapshots PC's address", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          const Text(
            "Use the PC's Tailscale name or address and the port Snapshots runs on, like "
            'mypc.tail1234.ts.net:8000 or 100.101.102.103:8000. Snapshots shows it in Settings on the PC.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _server,
            keyboardType: TextInputType.url,
            autocorrect: false,
            textInputAction: TextInputAction.go,
            decoration: const InputDecoration(labelText: 'Address', hintText: '100.101.102.103:8000'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _connect(),
          ),
          if (Api.unencrypted(_server.text)) ...[
            const SizedBox(height: 12),
            _Warning(
              'This is not a Tailscale address, and the connection is not encrypted: your password and '
              'photos travel over this network as they are, for others on it to read. Use the PC\'s '
              'Tailscale address (100.x.y.z or a name ending in .ts.net) if you can.',
            ),
          ],
        ];
      case _Step.password:
        return [
          Text('Sign in to ${session.server.replaceFirst(RegExp('^https?://'), '')}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _user,
            autocorrect: false,
            autofillHints: const [AutofillHints.username],
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'User name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pass,
            obscureText: !_showPass,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _login(),
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                tooltip: _showPass ? 'Hide password' : 'Show password',
                icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _showPass = !_showPass),
              ),
            ),
          ),
        ];
      case _Step.code:
        return [
          Text('Two-step login', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          const Text('Type the 6-digit code from your authenticator app, or one of your recovery codes.'),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            autofocus: true,
            autocorrect: false,
            autofillHints: const [AutofillHints.oneTimeCode],
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _sendCode(),
            decoration: const InputDecoration(labelText: 'Code'),
          ),
        ];
    }
  }
}

/// A note that something is risky, but allowed.
class _Warning extends StatelessWidget {
  const _Warning(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.errorContainer, borderRadius: BorderRadius.circular(12)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.warning_amber_rounded, color: c.onErrorContainer),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(color: c.onErrorContainer))),
      ]),
    );
  }
}
