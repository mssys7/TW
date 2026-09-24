# Offline Push-To-Talk (PTT) Walkie-Talkie
A production-ready offline Push-To-Talk walkie-talkie for Android & iOS.
Zero internet, zero cell service, zero central servers required.
Communicates peer-to-peer using Wi-Fi Direct and Bluetooth Low Energy (BLE).

## 🚀 Instant Android APK Build via GitHub Actions (Free)
This repository includes an automated GitHub Actions cloud builder: `.github/workflows/build-apk.yml`.

1. Push or upload this project to a GitHub repository.
2. Go to the **Actions** tab on your GitHub repository.
3. The workflow builds your release APK in ~2 minutes.
4. When finished:
   - Go to **Releases** on the right sidebar → download **`app-release.apk`**
   - Or click the workflow run → scroll to the bottom → download **`offline-walkie-talkie-apk`**.

## 💻 Local CLI Build
```bash
flutter pub get
flutter build apk --release
```
Output APK: `build/app/outputs/flutter-apk/app-release.apk`
