# TranslateGPT

A native macOS English-to-Simplified-Chinese translator. Select text in another app to see a floating, Chinese-only translation panel. For text in images, scanned PDFs or inaccessible app views, explicitly select a screen region for local OCR.

This repository contains the 0.2.8 source, adapted for a self-contained build and local conversation configuration. It does not include a prebuilt app, personal configuration, runtime state or development backups.

## Features

- Automatic translation of eligible English selections exposed through macOS Accessibility.
- A copy fallback, with clipboard restore, for apps that do not expose selected text to Accessibility.
- Visible **Turn On**, **Turn Off** and **Quit** controls, plus per-app exclusions.
- Explicit region OCR with **Control–Option–Command–T**; Escape cancels.
- Background use of one configured ChatGPT conversation in Safari, with Instant mode.
- Progressive output, a bounded in-memory translation cache and cancellation of obsolete requests.
- Owned engine-tab recovery after index shifts and page reloads; fresh owned windows when an engine tab or window is lost.
- Draft preservation and protection against automatically replaying an uncertain submission.

Fresh GPT replies depend on the website and can take several seconds. One-second complete translations are not guaranteed.

## Requirements

- macOS 15.0 or later. Region OCR requires macOS 15.2 or later.
- Xcode Command Line Tools with a macOS SDK that includes the rectangle screenshot API used in `RegionOCR.swift`.
- Python 3 for build-time configuration. Node.js is required only for the JavaScript tests.
- Safari, signed in to an account with access to the conversation you configure.

The app uses the ordinary ChatGPT website through Safari automation. It does not call a translation API or require an API key.

## Configure and build

Create or choose the conversation you want to dedicate to translation, then copy its URL from Safari. The app itself does not create a ChatGPT conversation.

```sh
cp config/Engine.example.json config/Engine.local.json
```

Edit `config/Engine.local.json` and replace the synthetic example URL with your conversation URL. Both `/c/<UUID>` and `/g/<project>/c/<UUID>` URLs are supported. Use `https://chatgpt.com` without credentials, query parameters or a fragment.

```sh
./build.sh
```

The result is `build/TranslateGPT.app`. The build creates the app bundle from tracked source and `Resources/Info.plist`; it never copies or modifies an installed app. By default it uses local ad-hoc signing. Set `TRANSLATEGPT_SIGN_IDENTITY` if you have a signing identity. An ad-hoc signature changes with every build, so macOS stops honouring the existing Accessibility and Screen Recording permissions after each update; signing every build with the same identity (for example a self-signed code-signing certificate in your login keychain) keeps them.

To select another configuration file, set `TRANSLATEGPT_CONFIG`. To verify a build using only the synthetic example:

```sh
TRANSLATEGPT_CONFIG="$PWD/config/Engine.example.json" ./build.sh
```

Do not use that synthetic configuration for real translation. Your local configuration and all generated files are ignored by Git. A built app necessarily embeds its configured conversation URL; review your configuration before distributing a binary.

## Install and permissions

Copy the built app to your preferred Applications directory, then open it. This build uses bundle identifier `com.xw.quickselecttranslate`; installing it over an existing TranslateGPT replaces that app.

- Enable **Accessibility** for native text selections.
- Allow TranslateGPT to control **Safari** when macOS asks, and enable Safari's **Allow JavaScript from Apple Events** setting.
- **Screen Recording** is requested only when you invoke region OCR. Denial leaves ordinary selection translation available.

After a rebuild with a different signature, a permission switch can stay on in System Settings without applying to the new build: remove TranslateGPT from that list with –, add it again with +, then reopen the app. The controls window warns when Accessibility is not in effect. This repository's build and test scripts do not change permissions or install the app.

## Use

Open TranslateGPT to show its controls. **Turn On / Turn Off** toggles automatic translation; closing the controls keeps the app running. Its menu-bar book icon also offers exclusions and region OCR.

Select eligible English text in another app. Unsupported selections remain silent; a selection that is only a link, email address, file name or IP address is skipped, while text that merely mentions one is translated. Use **Control–Option–Command–T** for a region that needs OCR, drag a rectangle and release, or press Escape to cancel. The panel supports scrolling, copying the translation and closing.

Safari must be running and signed in. The app creates and reuses its own minimized engine window and unpinned tab. Other ChatGPT tabs may stay in front. If an already submitted request loses its response page, the app reports an interruption and does not replay it automatically; select text again to start a new request. If ChatGPT shows neither output nor a Stop control for 20 seconds after a submission (for example after a website error), the app reports that the request got no response, does not resend it, and accepts your next selection.

## Privacy and limits

- Selected text or locally recognized OCR text is sent to your configured ChatGPT conversation.
- Screenshots stay temporary in memory; the app does not save or upload them.
- OCR runs on-device, only after explicit region selection. It is not prewarmed.
- Selections are read through Accessibility. Only when an app exposes no readable selection does the app press ⌘C for that selection (**Copy fallback when selection is unreadable** in the menu, on by default), translate the copied plain text and put the previous clipboard back exactly. It never does this in password managers, Finder, secure input or on window title bars and controls. A clipboard manager may still record the copied text. The app never reads whole source documents or extracts browser authentication data.
- Translation history can remain in your ChatGPT conversation. The app's separate cache is memory-only.
- Native selection support depends on what the source app exposes. In Electron apps (for example the Claude desktop app), the first selection that cannot be read makes TranslateGPT ask that app to expose its text to Accessibility, then read the selection again; code editors such as VS Code and Cursor are excluded because they switch to screen-reader mode. Secure fields and protected content can be unavailable.
- Safari automation depends on the website's UI and may need maintenance when that UI changes.

## Tests

```sh
./test.sh
```

The default suite uses synthetic configuration and fixtures. It does not send requests, open Safari, capture the screen or launch/install TranslateGPT.

An optional on-device OCR check draws synthetic text in memory:

```sh
./test.sh --vision-check
```

See [testing coverage](docs/TESTING.md) for the distinction between offline tests and prior live validation. No license has been selected for this initial publication.
