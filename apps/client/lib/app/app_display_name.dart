import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

/// Reads the Windows display language independently of regional settings.
final _getUserDefaultUiLanguage = DynamicLibrary.open(
  'kernel32.dll',
).lookupFunction<Uint16 Function(), int Function()>('GetUserDefaultUILanguage');

/// The application name shown by the system for the current language.
String get appDisplayName {
  // The low ten bits of a Windows LANGID identify its primary language.
  final isChinese = Platform.isWindows
      ? (_getUserDefaultUiLanguage() & 0x03ff) == 0x0004
      : PlatformDispatcher.instance.locale.languageCode == 'zh';
  return isChinese ? '知序' : 'Omni Butler';
}
