# Android Studio + Flutter Setup on Windows

## Do not create a new Android project

The **No Activity / New Project** screen is not needed. Click **Cancel**. This source already contains the complete Flutter project and Android package. Creating a new project would give it the wrong package name and signing setup.

Open this existing folder later:

```text
SpicyChat-QOL-Source\android_app
```

## 1. Install the Flutter SDK

1. Install Git for Windows.
2. Download the current stable Flutter SDK for Windows.
3. Extract it somewhere simple, for example `C:\src\flutter`. Do not put it in Program Files.
4. Add `C:\src\flutter\bin` to your Windows user `Path`.
5. Close and reopen PowerShell.
6. Run:

```powershell
flutter --version
flutter doctor -v
```

Installing only the Android Studio Flutter plugin is not enough; the Flutter SDK must also be installed and available in PowerShell.

## 2. Install the Android SDK components

In Android Studio, from the welcome screen choose **More Actions > SDK Manager**. If a project is already open, use **Tools > SDK Manager**.

Under **SDK Platforms**, install:

- Android 16 / API 36 platform

Under **SDK Tools**, install or update:

- Android SDK Build-Tools 36 (latest 36.x.x)
- Android SDK Command-line Tools (latest)
- Android SDK Platform-Tools
- Android Emulator (optional)
- Google USB Driver (useful for a physical Android phone on Windows)

Click **Apply**, then **OK**.

## 3. Install the Flutter plugin

In Android Studio open **File > Settings > Plugins > Marketplace**, search for **Flutter**, and install it. Accept the Dart plugin when prompted, then restart Android Studio.

## 4. Accept Android licences

Open PowerShell and run:

```powershell
flutter doctor --android-licenses
```

Press `y` for each licence, then run:

```powershell
flutter doctor -v
```

For building this APK, the Android toolchain section needs to be green. Visual Studio warnings for Windows desktop apps can be ignored because this project targets Android.

## 5. Open the existing app

In Android Studio choose **Open**, then select:

```text
SpicyChat-QOL-Source\android_app
```

Do not select **New Project**. Android Studio may ask for the Flutter SDK path; select the folder where you extracted Flutter, such as `C:\src\flutter`. Wait for Gradle and Dart indexing to finish.

## 6. Build the signed APK

The simplest method is from the source root:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\build_android.ps1
```

Or double-click `build_android.bat`. The completed APK is copied to:

```text
output\SpicyChat-QOL.apk
```

You can also build manually:

```powershell
cd .\android_app
flutter clean
flutter pub get
flutter build apk --release
```

## 7. Physical phone testing

An emulator is optional. For a phone, enable Developer options and USB debugging, connect it by USB, and run `flutter devices`. You can also simply copy the finished APK to the phone and install it manually.
