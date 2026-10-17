# 知序


cd apps/client
$env:PUB_HOSTED_URL = 'https://pub.dev' # 与客户端锁文件及 CI 使用同一包源。
flutter pub get --enforce-lockfile # 校验锁定的依赖版本及摘要。
flutter run --no-pub -d windows // windows


emulator -avd omni_test -no-snapshot-load
flutter devices # 应看到: sdk gphone64 x86 64 (mobile) • emulator-5554 • android-x64 • Android 16
cd apps/client
flutter run --no-pub -d emulator-5554

