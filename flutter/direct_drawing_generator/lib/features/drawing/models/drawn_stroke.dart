import 'dart:ui';

class DrawnStroke {
  DrawnStroke({
    required this.points,
    required this.color,
    required this.strokeWidth,
    this.blendMode = BlendMode.srcOver,
  });

  final List<Offset> points;
  final Color color;
  final double strokeWidth;
  final BlendMode blendMode;

  bool get isDrawable => points.length > 1;

  DrawnStroke copyWith({
    List<Offset>? points,
    Color? color,
    double? strokeWidth,
    BlendMode? blendMode,
  }) {
    return DrawnStroke(
      points: points ?? this.points,
      color: color ?? this.color,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      blendMode: blendMode ?? this.blendMode,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'points': points.map((Offset p) => <String, double>{'dx': p.dx, 'dy': p.dy}).toList(),
      'color': color.value,
      'strokeWidth': strokeWidth,
      'blendMode': blendMode.index,
    };
  }

  factory DrawnStroke.fromJson(Map<String, dynamic> json) {
    return DrawnStroke(
      points: (json['points'] as List<dynamic>)
          .map((dynamic p) => Offset((p as Map<String, dynamic>)['dx'] as double, p['dy'] as double))
          .toList(),
      color: Color(json['color'] as int),
      strokeWidth: (json['strokeWidth'] as num).toDouble(),
      blendMode: BlendMode.values[json['blendMode'] as int],
    );
  }
}
