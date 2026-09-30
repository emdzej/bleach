import Foundation

extension Rules {
    /// Shipped defaults. Users extend these via `~/.config/bleach/rules.yaml`.
    ///
    /// Entries in the three `protected_*` lists are appended, so an overlay
    /// can never remove a shipped protection. That guarantee does not extend
    /// to the rest of the file: `regenerable_patterns` is also appended but
    /// adds ways for a path to be judged *safe*, and the thresholds are
    /// replaced outright. An overlay is the user's own config and is trusted
    /// to make bleach more aggressive if that is what it says.
    ///
    /// The alias entries here were verified against this machine's
    /// LaunchServices registry rather than guessed. Anything unverified is
    /// deliberately absent — a wrong alias silently mis-attributes a
    /// directory, which is worse than leaving it unresolved.
    public static let defaultYAML = #"""
    # ---------------------------------------------------------------------
    # Never touch. These win over every other rule.
    # ---------------------------------------------------------------------
    protected_bundle_prefixes:
      - com.apple.
      - group.com.apple.
      - com.microsoft.VSCode # workspace state is not reconstructible

    protected_path_contains:
      - CloudDocs
      - Mobile Documents
      - MobileSync            # iOS device backups: huge and irreplaceable
      - Keychains
      - /Mail/
      - /Messages/
      - AddressBook
      - /Calendars/
      - CallHistory
      - /Photos/
      - FileProvider
      - Accounts
      - Knowledge
      - Suggestions
      - Biome
      - /Trial/
      - Cryptex
      - com.apple.security
      - .licence
      - .license
      # bleach's own quarantine and journal. Excluded from scanning outright
      # (see ScanRoots), but a hand-written plan bypasses scanning entirely
      # and `apply` must still refuse it.
      - /.local/state/bleach
      # Xcode archives are shipped builds and their dSYMs: the only copy of
      # the symbols for a version already in users' hands. Path-scoped rather
      # than a protected name, so an unrelated directory called "Archives"
      # stays judgeable on its own evidence.
      - /Xcode/Archives
      # Key bindings, themes, breakpoints, snippets. Small, hand-made, and
      # not reconstructible.
      - /Xcode/UserData

    protected_names:
      # Credentials and key material. These are small, so bleach would never
      # propose them on size grounds — but "would never propose" is not a
      # safety guarantee, and being explicit is.
      - .ssh
      - .gnupg
      - .aws
      - .kube
      - .docker
      - .password-store
      - .authinfo
      - .netrc
      - .Trash
      - .cups
      - .gitconfig
      - CloudDocs
      - MobileMeAccounts.plist
      - Keychains
      - com.apple.finder.plist
      - Preferences

    # ---------------------------------------------------------------------
    # Directory name -> bundle identifier, for names that normalisation and
    # fuzzy matching cannot bridge on their own.
    # ---------------------------------------------------------------------
    aliases:
      "Code - Insiders": com.microsoft.VSCodeInsiders
      "Code": com.microsoft.VSCode
      "Claude": com.anthropic.claudefordesktop
      "Freelens": app.freelens.Freelens
      "BambuStudio": com.bambulab.bambu-studio
      "BambuStudioBeta": com.bambulab.bambu-studio
      "bruno": com.usebruno.app
      "Steam": com.valvesoftware.steam
      "Discord": com.hnc.Discord
      "Docker": com.docker.docker
      "Ghostty": com.mitchellh.ghostty
      "Raycast": com.raycast.macos
      "Google/Chrome": com.google.Chrome
      "IntelliJ": com.jetbrains.intellij
      "Idea": com.jetbrains.intellij

    # ---------------------------------------------------------------------
    # Regenerable state: safe to clear even when the owner is installed and
    # running. Matched as case-insensitive regex against the candidate name.
    # ---------------------------------------------------------------------
    regenerable_patterns:
      - "-updater$"            # electron-updater download leftovers
      - "updater-cache"
      - "^Cache$"
      - "Caches?$"
      - "^Cached"              # e.g. CachedExtensionVSIXs
      - "Code Cache"
      - "GPUCache"
      - "GrShaderCache"
      - "ShaderCache"
      - "DawnCache"
      - "DawnGraphiteCache"
      - "Crashpad"
      - "CrashReporter"
      - "^Service Worker$"
      - "^logs?$"
      - "\\.log$"
      - "^tmp$"
      - "^temp$"
      # Symbols copied off a device when you first attach it, re-extracted on
      # the next attach. Matches the watchOS and tvOS variants too, and is
      # routinely the largest thing under ~/Library/Developer.
      - "DeviceSupport$"

    # ---------------------------------------------------------------------
    # Regenerable *even though* the owner's bundle prefix is protected.
    #
    # This is the one list that can step around a tier-0 protection, so it is
    # deliberately tiny and every entry has to earn its place.
    #
    # Squirrel.Mac stages a downloaded update in `<bundle-id>.ShipIt`, which
    # means the directory inherits a vendor prefix that may be protected for a
    # completely unrelated reason: VS Code's *workspace state* is not
    # reconstructible, but its update staging area is — it is re-downloaded on
    # the next update check. Without this, 1.4 GB of stale installer payload
    # was permanently PROTECTED and never even proposed.
    #
    # Only the bundle-prefix heuristic is bypassed. A protected path, a
    # protected name, a live process, or a registered .app bundle living
    # inside all still win, and entries here are treated as regenerable
    # patterns in their own right.
    # ---------------------------------------------------------------------
    regenerable_despite_bundle_prefix:
      - "\\.ShipIt$"

    # ---------------------------------------------------------------------
    # Owners that ship their own cleanup with their own retention logic.
    # bleach reports the size and tells you the command; it does not
    # reimplement the policy.
    # ---------------------------------------------------------------------
    delegated_cleanups:
      "Homebrew": "brew cleanup --prune=all"
      "pnpm": "pnpm store prune"
      "Yarn": "yarn cache clean"
      "yarn": "yarn cache clean"
      "go-build": "go clean -cache"
      "ms-playwright": "npx playwright uninstall --all"
      "CocoaPods": "pod cache clean --all"
      "pip": "pip cache purge"
      "uv": "uv cache prune"
      "deno": "deno clean"
      "JetBrains": "JetBrains Toolbox > settings > clear old caches"
      "com.apple.dt.Xcode": "xcrun simctl delete unavailable"
      # Matched on the first path component, so every candidate under
      # ~/Library/Developer/CoreSimulator delegates. Deleting a device
      # directory by hand destroys that simulator's installed apps and data;
      # simctl removes only devices whose runtime is already gone.
      "CoreSimulator": "xcrun simctl delete unavailable"
      # Delegated rather than marked regenerable, even though a rebuild is all
      # it costs: DerivedData routinely holds a *registered* .app bundle — any
      # build you have launched — which the nested-app rule hard-protects. A
      # regenerable pattern therefore produced CACHE-SAFE or PROTECTED
      # depending on whether you had ever run the app, which is not a verdict
      # anyone can predict. Delegating states the remedy plainly instead.
      "DerivedData": "rm -rf ~/Library/Developer/Xcode/DerivedData  (Xcode rebuilds indexes)"
      # Build and package caches living in dotdirs. All redownloadable, all
      # large, none safe to blind-delete while a build is running.
      ".npm": "npm cache clean --force"
      ".yarn": "yarn cache clean"
      ".m2": "rm -rf ~/.m2/repository  (redownloaded by the next build)"
      ".gradle": "gradle --stop, then rm -rf ~/.gradle/caches"
      ".rustup": "rustup toolchain list, then rustup toolchain uninstall <old>"
      ".cargo": "cargo cache --autoclean  (needs cargo-cache)"
      ".espressif": "reinstall via the ESP-IDF installer when next needed"
      ".gem": "gem cleanup"
      ".cocoapods": "pod cache clean --all"
      ".nuget": "dotnet nuget locals all --clear"
      ".bun": "bun pm cache rm"

    # ---------------------------------------------------------------------
    # Thresholds
    # ---------------------------------------------------------------------
    stale_days: 180
    keep_versions: 1
    min_actionable_bytes: 10485760
    """#
}
