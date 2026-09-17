import Foundation

extension Rules {
    /// Shipped defaults. Users extend these via `~/.config/bleach/rules.yaml`;
    /// list entries are appended, so a user override can only ever add
    /// protections, never remove one.
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
