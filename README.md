# 知序


cd apps/client
flutter pub get // flutter pub get 会根据 pubspec.yaml 下载所有 Dart 包，只会在依赖变化时需要重跑。
flutter run -d windows // windows


emulator -avd omni_test -no-snapshot-load
flutter devices # 应看到: sdk gphone64 x86 64 (mobile) • emulator-5554 • android-x64 • Android 16
cd apps/client
flutter run -d emulator-5554

