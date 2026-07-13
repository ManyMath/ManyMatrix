import 'package:flutter/widgets.dart';
import 'package:manyui/manyui.dart';

/// Compact ManyMatrix mark used in app chrome and authentication surfaces.
class ManyMatrixMark extends StatelessWidget {
  const ManyMatrixMark({this.size = 32, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = MTheme.of(context).colors;
    final gap = size * 0.08;
    final cell = (size - gap * 2) / 3;

    Widget square(int column, int row, Color color) {
      return PositionedDirectional(
        start: column * (cell + gap),
        top: row * (cell + gap),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(cell * 0.22),
          ),
          child: SizedBox.square(dimension: cell),
        ),
      );
    }

    return Semantics(
      image: true,
      label: 'ManyMatrix',
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          children: <Widget>[
            square(0, 0, colors.primary),
            square(1, 0, colors.primary.withValues(alpha: 0.72)),
            square(2, 0, colors.primary.withValues(alpha: 0.42)),
            square(0, 1, colors.primary.withValues(alpha: 0.72)),
            square(1, 1, colors.primary),
            square(2, 1, colors.primary.withValues(alpha: 0.72)),
            square(0, 2, colors.primary.withValues(alpha: 0.42)),
            square(1, 2, colors.primary.withValues(alpha: 0.72)),
            square(2, 2, colors.primary),
          ],
        ),
      ),
    );
  }
}
