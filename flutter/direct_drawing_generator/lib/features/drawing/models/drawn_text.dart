import 'dart:ui';

class DrawnText {
  DrawnText({
    required this.text,
    required this.position,
    required this.color,
    required this.fontSize,
  });

  final String text;
  final Offset position;
  final Color color;
  final double fontSize;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'text': text,
      'position': <String, double>{'dx': position.dx, 'dy': position.dy},
      'color': color.value,
      'fontSize': fontSize,
    };
  }

  factory DrawnText.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> pos = json['position'] as Map<String, dynamic>;
    return DrawnText(
      text: json['text'] as String,
      position: Offset(pos['dx'] as double, pos['dy'] as double),
      color: Color(json['color'] as int),
      fontSize: (json['fontSize'] as num).toDouble(),
    );
  }
}
