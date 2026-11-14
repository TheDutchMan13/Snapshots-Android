# Snapshots for Android

The phone app for [Snapshots](https://github.com/TheDutchMan13/Snapshots), the self-hosted photo library for Windows. It backs up your phone's photos and videos to your own PC and lets you browse the whole library from anywhere, through Tailscale.

## What it does

- **Backup.** Sends new photos and videos from the camera (or the folders you choose, or everything on the phone) to Snapshots, automatically about once an hour or right away with **Back up now**. It can wait for Wi-Fi and for the charger if you like. Photos already in Snapshots aren't sent again: the phone asks the PC first, by each file's fingerprint (SHA-1). Locations are kept.
- **Photos.** The whole library as a timeline, newest first, with "On this day" memories at the top and **Jump to a month** for big libraries.
- **Viewer.** Swipe between photos, pinch to zoom, play videos (also Live and motion photos), see the details: date, place, camera, people, albums, tags and any text in the photo.
- **Albums.** Open, make, rename and delete albums; add photos to them or take them out. Albums are shared by everyone who uses the Snapshots PC.
- **Search.** By words, names, places and dates, or by what's in the photo. Browse places, trips and tags.
- **People.** Everyone Snapshots recognised; give names, hide faces you don't want to see.
- **More.** Favourites, videos, archive, the locked folder (with your PIN) and the trash.
- **Share and save.** Share photos to other apps, or save the originals to the phone.
- **Photos the PC lost are sent again.** Once a day, and whenever you tap Back up now, the app asks Snapshots whether it still has everything this phone sent. A photo whose file is gone from the PC (deleted there, or its folder emptied) is sent again while it is still on the phone. Needs Snapshots 0.14.7 or newer on the PC; with an older one nothing changes.
- **Free up space.** In Backup: remove the phone's own copies of photos and videos that are safely in Snapshots (backed up, unchanged since, and not in the PC's trash). Android asks you to confirm. Right before anything is removed, the app asks Snapshots again whether it sees each file on the PC's disk at that moment; a photo it can't confirm (deleted on the PC, in its trash, on a drive that isn't connected) stays on the phone. Needs Snapshots 0.14.7 or newer on the PC: an older one answers from its records, not its disk, and the app then refuses to remove anything.
- **Filter** any page by stars, colour label, pick or reject, size, shape, black and white, or camera.
- **Stars, labels, pick and reject**, the **date** (set it, or move a batch by some hours), the **location** (a town or coordinates) and a **description**, from the photo's details or for a selection.
- **Edit photos:** turn, mirror, straighten and crop. **Save** keeps only the recipe on the PC; your original file is not changed. An administrator can also choose **Save into the photo's file** (menu next to Save; needs Snapshots 0.15.0 or newer on the PC), which turns the file itself, JPEG and PNG only. The PC keeps the old file and can put it back.
- **Comments** on photos and albums, and **Activity**: what others commented and added to albums.
- **Calendar, Highlights, Events, Year in review and Pets**, under More.
- **Smart albums** that fill themselves from rules (people, words, what's in the photo, dates, stars), and a **slideshow** of any page.

## Getting it on your phone

1. Open the [Releases page](https://github.com/TheDutchMan13/Snapshots-Android/releases) on the phone and download `Snapshots.apk`. (Builds of every change are on the Actions tab, under each run's Artifacts.)
2. Open it. Android asks to allow installing apps from your browser once; allow it.
3. Open Snapshots, type your PC's Tailscale address and the port Snapshots uses (Snapshots uses port `8080` unless you changed it, for example `100.101.102.103:8080`; with Tailscale Serve the name alone works, `mypc.tail1234.ts.net`), and sign in.
4. Go to **More > Backup**, allow access to your photos, and turn on **Back up automatically**.

New versions install over the old one; your sign-in and backup history are kept.

Needs Android 7 or newer, and Snapshots 0.14.7 or newer on the PC.

## Reaching your PC

The app talks to Snapshots over plain HTTP, the same address you use in a browser. Use your PC's **Tailscale** address so it works away from home too: Tailscale encrypts the connection. Snapshots must be running on the PC (Settings > Windows and more > **Start with Windows** keeps it running).

## Building it yourself

You need [Flutter](https://docs.flutter.dev/get-started/install) (stable channel) and the Android SDK.

```
flutter pub get
flutter test
flutter build apk --release
```

The APK is in `build/app/outputs/flutter-apk/`. Release builds are signed with `android/upload-keystore.jks` as described in `android/key.properties`; neither is in git:

```
storeFile=../upload-keystore.jks
storePassword=…
keyAlias=snapshots
keyPassword=…
```

Without `key.properties` a release build stops with a message. For a test build signed with the debug key (it won't install over a real one), set `SNAPSHOTS_DEBUG_SIGNING=1`.

Android only installs an update with a higher build number. The APKs from GitHub use the workflow's run number as build number, the version in `pubspec.yaml` stays as it is. So a local build won't install over an APK from GitHub (and needs the same key): pass a build number above the last run number, like `flutter build apk --release --build-number 500`, or uninstall the app first.

### Tests against a real server

```
SNAPSHOTS_TEST_SERVER=127.0.0.1:8790 SNAPSHOTS_TEST_USER=hans SNAPSHOTS_TEST_PASSWORD='…' flutter test test/live_server_test.dart
SNAPSHOTS_TEST_SERVER=127.0.0.1:8790 flutter test test/screens_test.dart --update-goldens   # pictures of the screens in test/shots/
```

Use a demo library: the tests upload a small photo and move it to the trash and back.

## License

Copyright © 2026 Hans De Kryger. GNU General Public License v3.0, see [LICENSE](LICENSE).
