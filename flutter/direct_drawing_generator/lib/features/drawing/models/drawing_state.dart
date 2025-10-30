import 'dart:convert';
import 'dart:typed_data';

import 'drawn_stroke.dart';
import 'drawn_text.dart';
import 'generation_result.dart';

/// ドローイングの状態を表すモデル
class DrawingState {
  DrawingState({
    required this.strokes,
    required this.texts,
    this.referenceImageBytes,
    required this.generationResults,
  });

  final List<DrawnStroke> strokes;
  final List<DrawnText> texts;
  final Uint8List? referenceImageBytes;
  final List<GenerationResult> generationResults;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'strokes': strokes.map((DrawnStroke s) => s.toJson()).toList(),
      'texts': texts.map((DrawnText t) => t.toJson()).toList(),
      'referenceImageBytes': referenceImageBytes != null ? base64Encode(referenceImageBytes!) : null,
      'generationResults': generationResults.map((GenerationResult r) => r.toJson()).toList(),
    };
  }

  factory DrawingState.fromJson(Map<String, dynamic> json) {
    return DrawingState(
      strokes: (json['strokes'] as List<dynamic>?)
              ?.map((dynamic e) => DrawnStroke.fromJson(e as Map<String, dynamic>))
              .toList() ??
          <DrawnStroke>[],
      texts: (json['texts'] as List<dynamic>?)
              ?.map((dynamic e) => DrawnText.fromJson(e as Map<String, dynamic>))
              .toList() ??
          <DrawnText>[],
      referenceImageBytes: json['referenceImageBytes'] != null
          ? base64Decode(json['referenceImageBytes'] as String)
          : null,
      generationResults: (json['generationResults'] as List<dynamic>?)
              ?.map((dynamic e) => GenerationResult.fromJson(e as Map<String, dynamic>))
              .toList() ??
          <GenerationResult>[],
    );
  }

  String toJsonString() {
    return jsonEncode(toJson());
  }

  factory DrawingState.fromJsonString(String jsonString) {
    return DrawingState.fromJson(jsonDecode(jsonString) as Map<String, dynamic>);
  }

  static DrawingState empty() {
    return DrawingState(
      strokes: <DrawnStroke>[],
      texts: <DrawnText>[],
      generationResults: <GenerationResult>[],
    );
  }
}
