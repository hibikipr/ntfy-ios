#  ntfy iOS App
This is the iOS app for [ntfy](https://github.com/binwiederhier/ntfy) ([ntfy.sh](https://ntfy.sh)).

## Relevant Links

- [Android App - Feature Parity](docs/FEATURE_PARITY.md)
- [Getting Started - Development](docs/GETTING_STARTED.md)
- [Technical Limitations](docs/TECHNICAL_LIMITATIONS.md)

## Push Notifications Backend (Firebase)

The app no longer ships with a bundled Firebase project — push notifications are relayed through
whichever Firebase project you import yourself, so no one has to ship their own production
credentials with the app. Until a config is imported, the app runs normally (you can still browse
and manage subscriptions), but push delivery is disabled.

To set it up:

1. Create a Firebase project and register an iOS app in it with a bundle ID matching this app's
   (see [Getting Started](docs/GETTING_STARTED.md) for the full Firebase + APNs + ntfy server setup).
2. Download that iOS app's `GoogleService-Info.plist` from the Firebase console.
3. In the app, go to **Settings > Push Notifications Backend > Firebase configuration**, tap
   **Import GoogleService-Info.plist**, and select the file.
4. Force-quit and reopen the app — the new configuration is only picked up on the next launch.

Your self-hosted ntfy server also needs to be configured with a service account key from the same
Firebase project, or it won't be able to send pushes to it.

A **Remove configuration** option in the same screen reverts the app to the unconfigured state
(also requires a restart to take effect).

## Contact me
You can directly contact me **[on Discord](https://discord.gg/cT7ECsZj9w)** or [on Matrix](https://matrix.to/#/#ntfy:matrix.org) 
(bridged from Discord), or via the [GitHub issues](https://github.com/binwiederhier/ntfy/issues), or find more contact information
[on my website](https://heckel.io/about).

## License
Originally developed by [@Copephobia](https://github.com/Copephobia). He did the bulk of the work, and deserves most
of the credit. Thank you @Copephobia!

The app is now maintained with ❤️ by [Philipp C. Heckel](https://heckel.io).   
The project is licensed under the [MIT License](LICENSE).

