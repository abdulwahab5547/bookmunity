import 'package:flutter/material.dart';

import '../controllers/auth_controller.dart';
import '../design/brutal_theme.dart';
import '../design/brutal_widgets.dart';

/// "or" divider plus "Continue with Google", shared by login and signup.
/// Renders nothing where Google sign-in is not offered.
class GoogleSignInSection extends StatefulWidget {
  const GoogleSignInSection({this.popOnSuccess = false, super.key});

  /// Signup is pushed over the login page, so it closes itself once signed
  /// in and the auth gate takes over.
  final bool popOnSuccess;

  @override
  State<GoogleSignInSection> createState() => _GoogleSignInSectionState();
}

class _GoogleSignInSectionState extends State<GoogleSignInSection> {
  bool _loading = false;

  Future<void> _signIn() async {
    setState(() => _loading = true);
    try {
      final user = await AuthController().signInWithGoogle();
      if (user != null && widget.popOnSuccess && mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Exception: ', '')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthController.googleSignInAvailable) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      children: [
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('or', style: theme.textTheme.bodySmall),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: BrutalPressable(
            onPressed: _loading ? null : _signIn,
            backgroundColor: Colors.white,
            foregroundColor: BrutalColors.ink,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_loading)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const GoogleLogo(size: 20),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    _loading ? 'Connecting to Google…' : 'Continue with Google',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The four-colour Google "G", drawn so no image asset is needed.
class GoogleLogo extends StatelessWidget {
  const GoogleLogo({this.size = 20, super.key});

  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _GoogleLogoPainter());
}

class _GoogleLogoPainter extends CustomPainter {
  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.2;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    Paint arc(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    const degree = 3.141592653589793 / 180;
    // Angles run clockwise from 3 o'clock; the gap is at the upper right.
    canvas.drawArc(rect, -40 * degree, 85 * degree, false, arc(_blue));
    canvas.drawArc(rect, 45 * degree, 90 * degree, false, arc(_green));
    canvas.drawArc(rect, 135 * degree, 90 * degree, false, arc(_yellow));
    canvas.drawArc(rect, 225 * degree, 92 * degree, false, arc(_red));
    // The crossbar.
    canvas.drawRect(
      Rect.fromLTWH(
        size.width / 2,
        size.height / 2 - stroke / 2,
        size.width / 2,
        stroke,
      ),
      Paint()..color = _blue,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
