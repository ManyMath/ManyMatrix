import 'package:flutter/widgets.dart';
import 'package:manyui/manyui.dart';
import 'package:manyui_riverpod/manyui_riverpod.dart';

final themeModeProvider = mThemeModeProvider;

MThemeData manyMatrixLightTheme() {
  return MThemeData.workbenchLight(primary: const Color(0xFF087F70));
}

MThemeData manyMatrixDarkTheme() {
  return MThemeData.workbenchDark(primary: const Color(0xFF5CC7B5));
}
